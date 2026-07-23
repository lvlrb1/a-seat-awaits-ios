// Supabase client factories for the edge functions.
//  - serviceClient(): service-role client (bypasses RLS) for ledger writes,
//    rate-limit RPCs, admin link generation, and owner-context queries.
//  - clientForToken(): an anon client bound to a caller's JWT, used to validate
//    the token and to run RLS-scoped reads as that user.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { supabaseConfig } from "./env.ts";

export function serviceClient(): SupabaseClient {
  const { url, serviceRoleKey } = supabaseConfig();
  return createClient(url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

export function clientForToken(accessToken: string): SupabaseClient {
  const { url, anonKey } = supabaseConfig();
  return createClient(url, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}
