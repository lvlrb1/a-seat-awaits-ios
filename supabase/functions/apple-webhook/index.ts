// apple-webhook (PUBLIC — App Store Server Notifications V2)
// ----------------------------------------------------------------------------
// Keeps Supabase current when a subscription changes outside the app: renewals,
// cancellations, billing issues, refunds. Authenticity comes SOLELY from
// verifying the signedPayload's certificate chain against Apple's pinned root —
// there is no bearer auth on this endpoint, and nothing is trusted before the
// signature checks out.
//
// The user is resolved from the transaction's appAccountToken (the Supabase
// user UUID, set at purchase time), falling back to the stored
// apple_original_transaction_id. Notifications are idempotent via
// `apple_notification_log` (notificationUUID primary key). Always returns 200
// for notifications we understand-but-skip, so Apple doesn't retry forever.

import { handlePreflight } from "../_shared/cors.ts";
import { HttpError, errorResponse, jsonResponse, logInfo, logWarn, newCorrelationId } from "../_shared/errors.ts";
import { serviceClient } from "../_shared/supabase.ts";
import {
  OFFER_TYPE_INTRODUCTORY,
  PASS_GUEST_CAPS,
  PASS_PRICE_CENTS,
  environmentLabel,
  isPassProduct,
  isoDate,
  paidCents,
  passTierForProduct,
  planForProduct,
  verifyNotification,
} from "../_shared/apple.ts";

const FN = "apple-webhook";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const cid = newCorrelationId();
  try {
    if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const signedPayload = typeof body.signedPayload === "string" ? body.signedPayload : "";
    if (!signedPayload) throw new HttpError(400, "Missing signedPayload.", { code: "missing_payload" });

    // 1. Verify the signature chain — this IS the authentication.
    let verified;
    try {
      verified = await verifyNotification(signedPayload);
    } catch (err) {
      logWarn(FN, cid, "signature_verify_failed", { err: String(err).slice(0, 160) });
      throw new HttpError(401, "Invalid signature.", { code: "invalid_signature" });
    }
    const { notification, transaction: tx, renewalInfo } = verified;
    const environment = environmentLabel(verified.environment);
    const type = notification.notificationType ?? "";
    const subtype = notification.subtype ?? "";
    const originalTxId = String(tx?.originalTransactionId ?? "");

    const admin = serviceClient();

    // 2. Idempotency: first writer wins on notificationUUID.
    const notificationUUID = notification.notificationUUID ?? "";
    if (notificationUUID) {
      const { data: inserted, error: logErr } = await admin
        .from("apple_notification_log")
        .upsert({
          notification_uuid: notificationUUID,
          notification_type: type,
          subtype,
          original_transaction_id: originalTxId || null,
          payload: { type, subtype, environment },
        }, { onConflict: "notification_uuid", ignoreDuplicates: true })
        .select("notification_uuid");
      if (logErr) {
        logWarn(FN, cid, "log_insert_failed", { err: logErr.message.slice(0, 160) });
      } else if (!inserted || inserted.length === 0) {
        logInfo(FN, cid, "duplicate", { type, subtype });
        return jsonResponse({ ok: true, duplicate: true });
      }
    }

    logInfo(FN, cid, "received", { type, subtype, environment });

    // TEST notifications (Request Test Notification) have no transaction.
    if (type === "TEST" || !tx) {
      return jsonResponse({ ok: true });
    }

    // 3. Event Pass one-time products take their own path — they live in
    //    `event_passes`, never in `subscriptions`. A pass never expires;
    //    a refund is the only thing that revokes one.
    if (isPassProduct(tx.productId)) {
      const txId = String(tx.transactionId ?? "");
      const signedISO = isoDate(notification.signedDate) ?? new Date().toISOString();

      switch (type) {
        case "REFUND":
        case "REVOKE": {
          // Match the payment that was refunded (upgrades overwrite the
          // stored transaction id, mirroring the Stripe payment-intent flow).
          const { data: revoked, error } = await admin
            .from("event_passes")
            .update({
              refunded_at: isoDate(tx.revocationDate) ?? signedISO,
              updated_at: new Date().toISOString(),
            })
            .eq("apple_transaction_id", txId)
            .is("refunded_at", null)
            .select("id");
          if (error) {
            logWarn(FN, cid, "pass_refund_update_failed", { err: error.message.slice(0, 160) });
            throw new HttpError(500, "Update failed.", { code: "update_failed" });
          }
          logInfo(FN, cid, "pass_refunded", { matched: (revoked ?? []).length });
          return jsonResponse({ ok: true });
        }

        case "ONE_TIME_CHARGE": {
          // Backstop for a purchase the app never managed to sync: record a
          // fresh base pass unattached (the DB attaches it to the buyer's
          // next event). Idempotent via the unique apple_transaction_id.
          // Upgrades are skipped — only the app knows the target event, and
          // its unfinished-transaction retry loop owns that path.
          const tier = passTierForProduct(tx.productId);
          const buyer = (tx.appAccountToken ?? "").toLowerCase();
          if (!tier || !UUID_RE.test(buyer)) {
            logInfo(FN, cid, "pass_charge_skipped", { hasTier: !!tier, hasBuyer: UUID_RE.test(buyer) });
            return jsonResponse({ ok: true, skipped: "unattributable" });
          }
          const { error } = await admin
            .from("event_passes")
            .upsert({
              event_id: null,
              user_id: buyer,
              tier,
              guest_cap: PASS_GUEST_CAPS[tier],
              amount_paid_cents: paidCents(tx.price, PASS_PRICE_CENTS[tier]),
              currency: (tx.currency ?? "usd").toLowerCase(),
              provider: "apple",
              apple_transaction_id: txId,
            }, { onConflict: "apple_transaction_id", ignoreDuplicates: true });
          if (error) {
            logWarn(FN, cid, "pass_charge_insert_failed", { err: error.message.slice(0, 160) });
            throw new HttpError(500, "Insert failed.", { code: "insert_failed" });
          }
          logInfo(FN, cid, "pass_charge_recorded", { tier });
          return jsonResponse({ ok: true });
        }

        case "CONSUMPTION_REQUEST":
          // Apple asks whether the pass was consumed before deciding a refund.
          // Policy: unused passes are refundable, no questions asked (the web
          // admin usage snapshot lives at server/api/admin/pass-usage.get.ts).
          // No consumption response is sent yet — logged for manual follow-up.
          logInfo(FN, cid, "pass_consumption_request", { txId });
          return jsonResponse({ ok: true });

        default:
          logInfo(FN, cid, "pass_unhandled_type", { type, subtype });
          return jsonResponse({ ok: true });
      }
    }

    // 4. Resolve the user: appAccountToken (Supabase UUID) first, then the
    //    stored original transaction id.
    let userId = (tx.appAccountToken ?? "").toLowerCase();
    if (!UUID_RE.test(userId)) userId = "";
    let existing: { user_id: string; provider: string; status: string; current_period_end: string | null } | null = null;
    if (userId) {
      const { data } = await admin.from("subscriptions")
        .select("user_id,provider,status,current_period_end")
        .eq("user_id", userId).maybeSingle();
      existing = data;
    } else if (originalTxId) {
      const { data } = await admin.from("subscriptions")
        .select("user_id,provider,status,current_period_end")
        .eq("apple_original_transaction_id", originalTxId).maybeSingle();
      existing = data;
      userId = existing?.user_id ?? "";
    }
    if (!userId) {
      logWarn(FN, cid, "user_unresolved", { type, hasToken: !!tx.appAccountToken });
      return jsonResponse({ ok: true, skipped: "user_unresolved" });
    }

    // Never clobber a live Stripe row from an Apple notification.
    if (existing && existing.provider !== "apple" &&
        !["canceled", "incomplete_expired"].includes(String(existing.status ?? "").toLowerCase())) {
      logWarn(FN, cid, "stripe_row_active_skip", { type });
      return jsonResponse({ ok: true, skipped: "stripe_active" });
    }

    const plan = planForProduct(tx.productId);
    const nowISO = new Date().toISOString();
    const autoRenewDisabled = renewalInfo?.autoRenewStatus === 0;
    const signedDateISO = isoDate(notification.signedDate) ?? nowISO;

    /** Full row rebuild from the verified transaction (SUBSCRIBED, DID_RENEW,
     * UPGRADE): plan/periods/status all come from Apple's payload. */
    const fullRow = () => ({
      user_id: userId,
      provider: "apple",
      plan,
      status: tx.offerType === OFFER_TYPE_INTRODUCTORY ? "trialing" : "active",
      stripe_subscription_id: null,
      stripe_price_id: null,
      apple_original_transaction_id: originalTxId,
      apple_product_id: tx.productId,
      apple_environment: environment,
      current_period_start: isoDate(tx.purchaseDate),
      current_period_end: isoDate(tx.expiresDate),
      cancel_at_period_end: autoRenewDisabled,
      canceled_at: autoRenewDisabled ? signedDateISO : null,
      trial_end: tx.offerType === OFFER_TYPE_INTRODUCTORY ? isoDate(tx.expiresDate) : null,
      pending_plan: null,
      pending_plan_period_end: null,
      updated_at: nowISO,
    });

    const patch = async (fields: Record<string, unknown>) => {
      const { error } = await admin.from("subscriptions")
        .update({ ...fields, updated_at: nowISO })
        .eq("user_id", userId);
      if (error) throw new HttpError(500, "Update failed.", { code: "update_failed" });
    };

    const upsertFull = async () => {
      if (!plan) {
        logWarn(FN, cid, "unknown_product", { productId: tx.productId ?? "" });
        return;
      }
      // Skip stale, out-of-order period updates for the same subscription.
      if (existing && existing.provider === "apple" && existing.current_period_end &&
          typeof tx.expiresDate === "number" &&
          new Date(existing.current_period_end).getTime() > tx.expiresDate) {
        logInfo(FN, cid, "stale_period_skip", { type });
        return;
      }
      const { error } = await admin.from("subscriptions")
        .upsert(fullRow(), { onConflict: "user_id" });
      if (error) throw new HttpError(500, "Upsert failed.", { code: "upsert_failed" });
    };

    // 5. Apply the notification.
    switch (type) {
      case "SUBSCRIBED":
      case "DID_RENEW":
      case "ONE_TIME_CHARGE":
        await upsertFull();
        break;

      case "DID_CHANGE_RENEWAL_PREF":
        if (subtype === "DOWNGRADE") {
          const pendingPlan = planForProduct(renewalInfo?.autoRenewProductId);
          await patch({
            pending_plan: pendingPlan,
            pending_plan_period_end: isoDate(tx.expiresDate),
          });
        } else {
          // UPGRADE is effective immediately; no subtype = reverted change.
          await upsertFull();
        }
        break;

      case "DID_CHANGE_RENEWAL_STATUS":
        await patch({
          cancel_at_period_end: autoRenewDisabled,
          canceled_at: autoRenewDisabled ? signedDateISO : null,
        });
        break;

      case "DID_FAIL_TO_RENEW":
        if (subtype === "GRACE_PERIOD") {
          // Entitlement continues through the grace period.
          await patch({
            status: "active",
            current_period_end: isoDate(renewalInfo?.gracePeriodExpiresDate) ??
              isoDate(tx.expiresDate),
          });
        } else {
          await patch({ status: "past_due" });
        }
        break;

      case "GRACE_PERIOD_EXPIRED":
        await patch({ status: "past_due" });
        break;

      case "EXPIRED":
        await patch({ status: "canceled", canceled_at: signedDateISO });
        break;

      case "REVOKE":
      case "REFUND":
        await patch({
          status: "canceled",
          canceled_at: isoDate(tx.revocationDate) ?? signedDateISO,
          current_period_end: isoDate(tx.revocationDate) ?? isoDate(tx.expiresDate),
        });
        break;

      default:
        // RENEWAL_EXTENDED, CONSUMPTION_REQUEST, PRICE_INCREASE, etc. — logged
        // in apple_notification_log; no state change needed.
        logInfo(FN, cid, "unhandled_type", { type, subtype });
        break;
    }

    return jsonResponse({ ok: true });
  } catch (err) {
    if (!(err instanceof HttpError)) logWarn(FN, cid, "unexpected", { err: String(err).slice(0, 160) });
    return errorResponse(err, cid);
  }
});
