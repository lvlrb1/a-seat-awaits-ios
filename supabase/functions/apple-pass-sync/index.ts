// apple-pass-sync (AUTHENTICATED)
// ----------------------------------------------------------------------------
// Records an Event Pass purchase (or in-place upgrade) bought through Apple
// In-App Purchase. The iOS app posts the signed transaction JWS after buying a
// pass consumable; this function verifies it against Apple's root
// certificates, confirms it belongs to the calling user (appAccountToken), and
// writes `public.event_passes`. The app only `finish()`es the transaction
// after this returns 2xx, so failures here are retried when StoreKit
// redelivers the unfinished consumable via Transaction.updates — which is why
// every path is idempotent on the transaction id.
//
// A pass never expires; only a refund revokes it (see apple-webhook). A base
// pass may be bought unattached (no eventId) — the events AFTER INSERT trigger
// attaches it to the buyer's next event — or for a specific event. Upgrades
// always target an event and bump the existing row's tier/guest_cap/amount,
// overwriting apple_transaction_id with the upgrade's transaction id (the same
// way the Stripe webhook overwrites the payment-intent id), so a refund of the
// latest payment revokes the pass.
//
// Request:  { jws, eventId? }
// Response: { ok: true, pass: <event_passes row> }
// Errors:   401 unauthenticated · 403 wrong account/not yours · 400 malformed
//           404 no pass to upgrade · 409 pass exists / tier mismatch
//           422 unrecognized product

import { handlePreflight } from "../_shared/cors.ts";
import { HttpError, errorResponse, jsonResponse, logInfo, logWarn, newCorrelationId } from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { serviceClient } from "../_shared/supabase.ts";
import {
  PASS_GUEST_CAPS,
  PASS_PRICE_CENTS,
  PASS_UPGRADE_PRICE_CENTS,
  environmentLabel,
  paidCents,
  passTierForProduct,
  passUpgradeForProduct,
  verifyTransaction,
} from "../_shared/apple.ts";

const FN = "apple-pass-sync";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PASS_COLUMNS =
  "id,event_id,user_id,tier,guest_cap,amount_paid_cents,currency,provider," +
  "purchased_at,refunded_at,ai_imports_used";

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
    const eventId = typeof body.eventId === "string" && body.eventId.trim()
      ? body.eventId.trim()
      : null;
    if (eventId && !UUID_RE.test(eventId)) {
      throw new HttpError(400, "Invalid event id.", { code: "invalid_event_id" });
    }

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

    // 3. The purchase must be tagged with this user's id (appAccountToken).
    const token = (tx.appAccountToken ?? "").toLowerCase();
    if (!token || token !== user.id.toLowerCase()) {
      logWarn(FN, cid, "app_account_token_mismatch", { hasToken: !!token });
      throw new HttpError(403, "This purchase belongs to another A Seat Awaits account.", {
        code: "wrong_account",
      });
    }

    const productId = tx.productId ?? "";
    const txId = String(tx.transactionId ?? "");
    if (!txId) throw new HttpError(400, "The transaction has no id.", { code: "missing_transaction_id" });

    const admin = serviceClient();

    // 4. Idempotency: a transaction we've already recorded is a success —
    //    the app is just retrying an unfinished consumable.
    const { data: already } = await admin
      .from("event_passes")
      .select(PASS_COLUMNS)
      .eq("apple_transaction_id", txId)
      .maybeSingle();
    if (already) {
      logInfo(FN, cid, "duplicate_transaction", { productId, environment });
      return jsonResponse({ ok: true, pass: already });
    }

    const tier = passTierForProduct(productId);
    const upgrade = passUpgradeForProduct(productId);

    if (tier) {
      // ----- Fresh pass ------------------------------------------------------
      if (eventId) {
        const { data: event } = await admin
          .from("events")
          .select("id,owner_id,is_sample")
          .eq("id", eventId)
          .maybeSingle();
        if (!event || event.owner_id !== user.id) {
          throw new HttpError(403, "That event isn't yours.", { code: "not_your_event" });
        }
        if (event.is_sample) {
          throw new HttpError(400, "The sample event doesn't need a pass.", { code: "sample_event" });
        }
        const { data: existing } = await admin
          .from("event_passes")
          .select("id,refunded_at")
          .eq("event_id", eventId)
          .maybeSingle();
        if (existing) {
          throw new HttpError(409, "This event already has a pass. Upgrade it instead.", {
            code: "pass_exists",
          });
        }
      }

      const row = {
        event_id: eventId,
        user_id: user.id,
        tier,
        guest_cap: PASS_GUEST_CAPS[tier],
        amount_paid_cents: paidCents(tx.price, PASS_PRICE_CENTS[tier]),
        currency: (tx.currency ?? "usd").toLowerCase(),
        provider: "apple",
        apple_transaction_id: txId,
      };
      const { data: inserted, error: insertErr } = await admin
        .from("event_passes")
        .insert(row)
        .select(PASS_COLUMNS)
        .maybeSingle();
      if (insertErr) {
        // Unique violation on apple_transaction_id = concurrent retry → success.
        if (insertErr.code === "23505" && insertErr.message.includes("apple_transaction_id")) {
          const { data: winner } = await admin
            .from("event_passes")
            .select(PASS_COLUMNS)
            .eq("apple_transaction_id", txId)
            .maybeSingle();
          return jsonResponse({ ok: true, pass: winner ?? null });
        }
        if (insertErr.code === "23505") {
          throw new HttpError(409, "This event already has a pass. Upgrade it instead.", {
            code: "pass_exists",
          });
        }
        logWarn(FN, cid, "insert_failed", { err: insertErr.message.slice(0, 160) });
        throw new HttpError(500, "Couldn't record your pass. It will retry automatically.", {
          code: "insert_failed",
        });
      }
      logInfo(FN, cid, "pass_recorded", { tier, attached: !!eventId, environment });
      return jsonResponse({ ok: true, pass: inserted });
    }

    if (upgrade) {
      // ----- In-place upgrade ------------------------------------------------
      if (!eventId) {
        throw new HttpError(400, "An upgrade needs the event it applies to.", {
          code: "missing_event_id",
        });
      }
      const { data: pass } = await admin
        .from("event_passes")
        .select("id,user_id,tier,amount_paid_cents,refunded_at")
        .eq("event_id", eventId)
        .maybeSingle();
      if (!pass || pass.user_id !== user.id) {
        throw new HttpError(404, "There's no pass on that event to upgrade.", { code: "no_pass" });
      }
      if (pass.refunded_at) {
        throw new HttpError(409, "That pass was refunded and can't be upgraded.", {
          code: "pass_refunded",
        });
      }
      if (pass.tier !== upgrade.from) {
        throw new HttpError(409, "That upgrade doesn't match the event's current pass.", {
          code: "tier_mismatch",
        });
      }

      const paid = paidCents(tx.price, PASS_UPGRADE_PRICE_CENTS[productId] ?? 0);
      const { data: updated, error: updateErr } = await admin
        .from("event_passes")
        .update({
          tier: upgrade.to,
          guest_cap: PASS_GUEST_CAPS[upgrade.to],
          amount_paid_cents: (pass.amount_paid_cents ?? 0) + paid,
          apple_transaction_id: txId,
          updated_at: new Date().toISOString(),
        })
        .eq("id", pass.id)
        // Guard against a concurrent retry double-applying the amount: only
        // the first writer still sees the from-tier.
        .eq("tier", upgrade.from)
        .select(PASS_COLUMNS)
        .maybeSingle();
      if (updateErr) {
        logWarn(FN, cid, "upgrade_failed", { err: updateErr.message.slice(0, 160) });
        throw new HttpError(500, "Couldn't apply your upgrade. It will retry automatically.", {
          code: "upgrade_failed",
        });
      }
      if (!updated) {
        // Lost the race to another writer of the same transaction → success.
        const { data: winner } = await admin
          .from("event_passes")
          .select(PASS_COLUMNS)
          .eq("apple_transaction_id", txId)
          .maybeSingle();
        if (winner) return jsonResponse({ ok: true, pass: winner });
        throw new HttpError(409, "That upgrade doesn't match the event's current pass.", {
          code: "tier_mismatch",
        });
      }
      logInfo(FN, cid, "pass_upgraded", { to: upgrade.to, environment });
      return jsonResponse({ ok: true, pass: updated });
    }

    logWarn(FN, cid, "unknown_product", { productId });
    throw new HttpError(422, "Unrecognized pass product.", { code: "unknown_product" });
  } catch (err) {
    if (!(err instanceof HttpError)) logWarn(FN, cid, "unexpected", { err: String(err).slice(0, 160) });
    return errorResponse(err, cid);
  }
});
