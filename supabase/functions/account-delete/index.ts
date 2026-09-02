// account-delete (AUTHENTICATED)
// ----------------------------------------------------------------------------
// Permanently deletes the calling Supabase Auth user. The caller's identity is
// derived only from the verified JWT; no user id is accepted in the request.
// The `cleanup_deleted_account_entitlements` database trigger deletes every
// subscription and Event Pass owned by the user in the same transaction as the
// auth deletion. Existing cascades remove the profile, owned events, event
// content, and preferences. Any cleanup failure aborts the whole deletion.
//
// Request:  { confirmation: "DELETE" }
// Response: { ok: true }

import { handlePreflight } from "../_shared/cors.ts";
import {
  HttpError,
  errorResponse,
  jsonResponse,
  logInfo,
  logWarn,
  newCorrelationId,
} from "../_shared/errors.ts";
import { requireUser } from "../_shared/auth.ts";
import { serviceClient } from "../_shared/supabase.ts";

const FN = "account-delete";
const REQUIRED_CONFIRMATION = "DELETE";

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  const cid = newCorrelationId();
  try {
    if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

    const user = await requireUser(req);
    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
    const confirmation = typeof body.confirmation === "string"
      ? body.confirmation.trim().toUpperCase()
      : "";
    if (confirmation !== REQUIRED_CONFIRMATION) {
      throw new HttpError(400, "Type DELETE to confirm account deletion.", {
        code: "confirmation_required",
      });
    }

    const admin = serviceClient();
    const { error } = await admin.auth.admin.deleteUser(user.id);
    if (error) {
      logWarn(FN, cid, "delete_failed", { status: error.status ?? 500 });
      throw new HttpError(
        500,
        "Your account could not be deleted. Please try again or contact support.",
        { code: "delete_failed" },
      );
    }

    logInfo(FN, cid, "success");
    return jsonResponse({ ok: true });
  } catch (err) {
    if (!(err instanceof HttpError)) {
      logWarn(FN, cid, "unexpected", { kind: err instanceof Error ? err.name : "unknown" });
    }
    return errorResponse(err, cid);
  }
});
