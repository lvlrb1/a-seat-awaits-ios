// Centralized, fail-closed environment access for the edge functions.
// Required secrets are read from Supabase Edge Function secret management. If a
// required value is absent the function FAILS CLOSED (throws) rather than
// silently falling back to a testing sender such as onboarding@resend.dev.
// No real secret values live in source — see functions/.env.example.

const PROD_ORIGIN = "https://aseatawaits.com";

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value.trim();
}

export function optionalEnv(name: string): string | undefined {
  const value = Deno.env.get(name);
  return value && value.trim() ? value.trim() : undefined;
}

/** Public site origin (no trailing slash). Never throws — used during template
 * render; falls back to the production origin so chrome always renders. */
export function siteUrlSync(): string {
  const raw = optionalEnv("PUBLIC_SITE_URL") ?? PROD_ORIGIN;
  return raw.replace(/\/+$/, "");
}

export interface SupabaseConfig {
  url: string;
  anonKey: string;
  serviceRoleKey: string;
}

export function supabaseConfig(): SupabaseConfig {
  return {
    url: requireEnv("SUPABASE_URL"),
    anonKey: requireEnv("SUPABASE_ANON_KEY"),
    serviceRoleKey: requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
  };
}
