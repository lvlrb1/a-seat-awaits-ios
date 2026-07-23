// apple-iap-sync (AUTHENTICATED)
// ----------------------------------------------------------------------------
// Activates an App Store purchase server-side. The iOS app posts the signed
// transaction JWS (Transaction.jwsRepresentation) after a purchase, restore, or
// entitlement re-sync; this function verifies it against Apple's root
// certificates, confirms it belongs to the calling user (appAccountToken), and
// upserts the user's `public.subscriptions` row (the on_subscription_change
// trigger keeps `public.users` in sync). The app only `finish()`es the
// transaction after this returns 2xx, so failures here are retried by StoreKit.
//
// Request:  { jws }
// Response: { ok: true, subscription: <subscriptions row> }
// Errors:   401 unauthenticated · 403 wrong account · 409 active Stripe billing
//           422 unrecognized product · 400 malformed

import { handlePreflight } from "../_shared/cors.ts";
import { HttpError, errorResponse, jsonResponse, logInfo, logWarn, newCorrelationId } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { serviceClient } from "../_shared/supabase.ts";
import {
  OFFER_TYPE_INTRODUCTORY,
  environmentLabel,
  isoDate,
  planForProduct,
  verifyTransaction,
} from "../_shared/apple.ts";

const FN = "apple-iap-sync";

/** Stripe statuses that must block an Apple purchase from claiming the row. */
const STRIPE_BLOCKING_STATUSES = new Set([
  "active", "trialing", "past_due", "unpaid", "incomplete", "paused",
]);

const SUBSCRIPTION_COLUMNS =
  "plan,status,provider,stripe_price_id,apple_product_id,current_period_start," +
  "current_period_end,cancel_at_period_end,canceled_at,trial_end,created_at,updated_at";

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const cid = newCorrelationId();
  try {
    if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

    // 1. Identity comes from the verified JWT, never the body.
    const user = await requireUser(req);

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const jws = typeof body.jws === "string" ? body.jws.trim() : "";
    if (!jws) throw new HttpError(400, "Missing transaction.", { code: "missing_jws" });

    // 2. Verify the JWS signature chain against Apple's pinned root.
    let verified;
    try {
      verified = await verifyTransaction(jws);
    } catch (err) {
      logWarn(FN, cid, "jws_verify_failed", { err: String(err).slice(0, 160) });
      throw new HttpError(400, "The App Store receipt couldn't be verified.", { code: "invalid_jws" });
    }
    const tx = verified.transaction;
    const environment = environmentLabel(verified.environment);

    // 3. The purchase must be tagged with this user's id (set by the app via
    //    appAccountToken at purchase time). Blocks replaying someone else's JWS
    //    and restoring under the wrong A Seat Awaits account.
    const token = (tx.appAccountToken ?? "").toLowerCase();
    if (!token || token !== user.id.toLowerCase()) {
      logWarn(FN, cid, "app_account_token_mismatch", { hasToken: !!token });
      throw new HttpError(403, "This purchase belongs to another A Seat Awaits account.", {
        code: "wrong_account",
      });
    }

    const plan = planForProduct(tx.productId);
    if (!plan) {
      logWarn(FN, cid, "unknown_product", { productId: tx.productId ?? "" });
      throw new HttpError(422, "Unrecognized subscription product.", { code: "unknown_product" });
    }

    // 4. Never clobber live Stripe billing — the web subscription must be
    //    resolved there first. (The app hides purchase UI for these users; this
    //    is defense in depth.)
    const admin = serviceClient();
    const { data: existing } = await admin
      .from("subscriptions")
      .select("provider,status")
      .eq("user_id", user.id)
      .maybeSingle();
    if (existing && existing.provider !== "apple" &&
        STRIPE_BLOCKING_STATUSES.has(String(existing.status ?? "").toLowerCase())) {
      throw new HttpError(409, "You already have a subscription through our website.", {
        code: "stripe_active",
      });
    }

    // 5. Derive status from the verified transaction.
    const now = Date.now();
    const revoked = typeof tx.revocationDate === "number" && tx.revocationDate > 0;
    const expired = typeof tx.expiresDate === "number" && tx.expiresDate <= now;
    const isIntro = tx.offerType === OFFER_TYPE_INTRODUCTORY;
    const status = revoked || expired ? "canceled" : isIntro ? "trialing" : "active";

    const row = {
      user_id: user.id,
      provider: "apple",
      plan,
      status,
      stripe_subscription_id: null,
      stripe_price_id: null,
      apple_original_transaction_id: String(tx.originalTransactionId ?? tx.transactionId ?? ""),
      apple_product_id: tx.productId,
      apple_environment: environment,
      current_period_start: isoDate(tx.purchaseDate),
      current_period_end: isoDate(tx.expiresDate),
      cancel_at_period_end: false,
      canceled_at: revoked ? isoDate(tx.revocationDate) : null,
      trial_end: isIntro ? isoDate(tx.expiresDate) : null,
      pending_plan: null,
      pending_plan_period_end: null,
      updated_at: new Date().toISOString(),
    };

    const { error: upsertErr } = await admin
      .from("subscriptions")
      .upsert(row, { onConflict: "user_id" });
    if (upsertErr) {
      logWarn(FN, cid, "upsert_failed", { err: upsertErr.message.slice(0, 160) });
      throw new HttpError(500, "Couldn't activate your plan. It will retry automatically.", {
        code: "upsert_failed",
      });
    }

    const { data: canonical } = await admin
      .from("subscriptions")
      .select(SUBSCRIPTION_COLUMNS)
      .eq("user_id", user.id)
      .maybeSingle();

    logInfo(FN, cid, "success", { plan, status, environment });
    return jsonResponse({ ok: true, subscription: canonical ?? null });
  } catch (err) {
    if (!(err instanceof HttpError)) logWarn(FN, cid, "unexpected", { err: String(err).slice(0, 160) });
    return errorResponse(err, cid);
  }
});
