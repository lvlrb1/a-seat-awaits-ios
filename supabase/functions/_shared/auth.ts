// JWT verification for authenticated edge functions. The caller's identity is
// derived ONLY from the verified Supabase JWT — never from the request body.

import { HttpError } from "./errors.ts";
import { clientForToken } from "./supabase.ts";

export interface AuthedUser {
  id: string;
  email: string | null;
  accessToken: string;
}

function bearerToken(req: Request): string {
  const header = req.headers.get("Authorization") ?? req.headers.get("authorization");
  if (!header || !header.toLowerCase().startsWith("bearer ")) {
    throw new HttpError(401, "You must be signed in.", { code: "unauthenticated" });
  }
  const token = header.slice(7).trim();
  if (!token) {
    throw new HttpError(401, "You must be signed in.", { code: "unauthenticated" });
  }
  return token;
}

/** Verifies the JWT against the Supabase project and returns the user. The
 * anon `apikey` header that Supabase's gateway requires is added by the client
 * (iOS) — gateway-level verify_jwt is disabled for these functions so we can
 * return a structured 401 instead of an opaque gateway error. */
export async function requireUser(req: Request): Promise<AuthedUser> {
  const token = bearerToken(req);
  const supabase = clientForToken(token);
  const { data, error } = await supabase.auth.getUser();
  if (error || !data?.user) {
    throw new HttpError(401, "Your session has expired. Please sign in again.", { code: "session_expired" });
  }
  return { id: data.user.id, email: data.user.email ?? null, accessToken: token };
}
