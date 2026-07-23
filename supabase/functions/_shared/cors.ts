// CORS handling for the edge functions. The iOS app calls these from outside a
// browser, but the headers also let a developer preview/test from a web origin.
// We allow the standard Supabase function headers and the methods we use.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-correlation-id",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** Returns a preflight response when the request is an OPTIONS request. */
export function handlePreflight(req: Request): Response | null {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  return null;
}
