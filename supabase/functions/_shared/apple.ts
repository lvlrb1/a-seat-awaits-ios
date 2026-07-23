// Apple App Store verification + product mapping for the IAP edge functions.
//
// Every signed payload (transaction JWS from the app, notification from Apple)
// is verified against Apple's pinned root certificate before anything is
// trusted — possession of a JWS proves nothing until the x5c chain checks out.
// The Apple Root CA G3 certificate is fetched from apple.com once per isolate
// and cached; no binary blobs live in source.
//
// Environments: staging accepts Sandbox; production accepts Production AND
// Sandbox (TestFlight builds produce Sandbox-signed transactions while talking
// to the production backend). Override with APPLE_ACCEPT_ENVIRONMENTS.

import { Buffer } from "node:buffer";
import {
  Environment,
  SignedDataVerifier,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
} from "npm:@apple/app-store-server-library@1";

import { optionalEnv } from "./env.ts";

const APPLE_ROOT_CA_URL = "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer";
const DEFAULT_BUNDLE_ID = "heartlineeventsolutionsllc.A-Seat-Awaits";

export function appleBundleId(): string {
  return optionalEnv("APPLE_BUNDLE_ID") ?? DEFAULT_BUNDLE_ID;
}

/** Which App Store environments this deployment trusts. */
export function acceptedEnvironments(): Environment[] {
  const raw = optionalEnv("APPLE_ACCEPT_ENVIRONMENTS") ?? "Production,Sandbox";
  return raw.split(",")
    .map((s) => s.trim().toLowerCase())
    .flatMap((s) => {
      if (s === "production") return [Environment.PRODUCTION];
      if (s === "sandbox") return [Environment.SANDBOX];
      return [];
    });
}

let cachedRoots: Buffer[] | null = null;

async function appleRootCertificates(): Promise<Buffer[]> {
  if (cachedRoots) return cachedRoots;
  const res = await fetch(APPLE_ROOT_CA_URL);
  if (!res.ok) throw new Error(`Failed to fetch Apple root certificate (${res.status})`);
  cachedRoots = [Buffer.from(await res.arrayBuffer())];
  return cachedRoots;
}

const verifiers = new Map<Environment, SignedDataVerifier>();

async function verifierFor(environment: Environment): Promise<SignedDataVerifier> {
  const existing = verifiers.get(environment);
  if (existing) return existing;
  const roots = await appleRootCertificates();
  // appAppleId is required by the library for Production verification; it's the
  // numeric App Store app id (APPLE_APP_APPLE_ID secret).
  const appAppleIdRaw = optionalEnv("APPLE_APP_APPLE_ID");
  const appAppleId = appAppleIdRaw ? Number(appAppleIdRaw) : undefined;
  // Online (OCSP) revocation checks are disabled: they add a network hop per
  // request and are unreliable under the edge runtime. The pinned-root chain
  // validation still runs.
  const verifier = new SignedDataVerifier(
    roots, false, environment, appleBundleId(), appAppleId);
  verifiers.set(environment, verifier);
  return verifier;
}

/** Tries each accepted environment until one verifies the payload. */
async function verifyAcrossEnvironments<T>(
  verify: (v: SignedDataVerifier) => Promise<T>,
): Promise<{ payload: T; environment: Environment }> {
  let lastError: unknown = new Error("No accepted App Store environments configured");
  for (const environment of acceptedEnvironments()) {
    try {
      const payload = await verify(await verifierFor(environment));
      return { payload, environment };
    } catch (err) {
      lastError = err;
    }
  }
  throw lastError;
}

export interface VerifiedTransaction {
  transaction: JWSTransactionDecodedPayload;
  environment: Environment;
}

/** Verifies a signed transaction JWS (from the app) and decodes it. */
export async function verifyTransaction(jws: string): Promise<VerifiedTransaction> {
  const { payload, environment } = await verifyAcrossEnvironments(
    (v) => v.verifyAndDecodeTransaction(jws));
  return { transaction: payload, environment };
}

export interface VerifiedNotification {
  notification: ResponseBodyV2DecodedPayload;
  transaction: JWSTransactionDecodedPayload | null;
  renewalInfo: JWSRenewalInfoDecodedPayload | null;
  environment: Environment;
}

/** Verifies an App Store Server Notification V2 signedPayload and decodes the
 * nested transaction/renewal payloads (each independently verified). */
export async function verifyNotification(signedPayload: string): Promise<VerifiedNotification> {
  const { payload: notification, environment } = await verifyAcrossEnvironments(
    (v) => v.verifyAndDecodeNotification(signedPayload));
  const verifier = await verifierFor(environment);
  const data = notification.data;
  const transaction = data?.signedTransactionInfo
    ? await verifier.verifyAndDecodeTransaction(data.signedTransactionInfo)
    : null;
  const renewalInfo = data?.signedRenewalInfo
    ? await verifier.verifyAndDecodeRenewalInfo(data.signedRenewalInfo)
    : null;
  return { notification, transaction, renewalInfo, environment };
}

export function environmentLabel(environment: Environment): "Sandbox" | "Production" {
  return environment === Environment.PRODUCTION ? "Production" : "Sandbox";
}

// ---------------------------------------------------------------------------
// Product catalog — mirrors iOS `AppleProducts` and maps to the DB
// `billing_plan` enum (which uses the historical spellings basic/pro).

const PRODUCT_PLAN: Record<string, string> = {
  "aseatawaits.sub.core.monthly": "core",
  "aseatawaits.sub.core.annual": "core",
  "aseatawaits.sub.essentials.monthly": "basic",
  "aseatawaits.sub.essentials.annual": "basic",
  "aseatawaits.sub.signature.monthly": "pro",
  "aseatawaits.sub.signature.annual": "pro",
  "aseatawaits.sub.elite.monthly": "elite",
  "aseatawaits.sub.elite.annual": "elite",
};

/** Maps an App Store product id to the DB `billing_plan` value, or null. */
export function planForProduct(productId: string | undefined): string | null {
  if (!productId) return null;
  return PRODUCT_PLAN[productId] ?? null;
}

// ---------------------------------------------------------------------------
// Event Pass consumables (July 2026 pricing model) — mirrors iOS
// `PassProducts` and the web repo's shared/billing/plans.ts EVENT_PASSES.
// One pass = one event; a pass never expires (only a refund revokes it).

export type EventPassTier = "starter" | "standard" | "premium";

export const PASS_GUEST_CAPS: Record<EventPassTier, number> = {
  starter: 50,
  standard: 150,
  premium: 500,
};

/** Fallback prices in cents, used only when the signed transaction omits
 * `price` (older payload versions). Mirrors EVENT_PASSES prices. */
export const PASS_PRICE_CENTS: Record<EventPassTier, number> = {
  starter: 999,
  standard: 1999,
  premium: 3999,
};

const PASS_PRODUCT_TIER: Record<string, EventPassTier> = {
  "aseatawaits.pass.starter": "starter",
  "aseatawaits.pass.standard": "standard",
  "aseatawaits.pass.premium": "premium",
};

export interface PassUpgrade {
  from: EventPassTier;
  to: EventPassTier;
}

/** Pay-the-difference upgrade consumables (StoreKit can't charge an arbitrary
 * delta like Stripe, so each from→to pair is its own product). Prices mirror
 * passUpgradePrice() in the web repo. */
const PASS_UPGRADE_PRODUCTS: Record<string, PassUpgrade> = {
  "aseatawaits.pass.upgrade.starter_standard": { from: "starter", to: "standard" },
  "aseatawaits.pass.upgrade.standard_premium": { from: "standard", to: "premium" },
  "aseatawaits.pass.upgrade.starter_premium": { from: "starter", to: "premium" },
};

export const PASS_UPGRADE_PRICE_CENTS: Record<string, number> = {
  "aseatawaits.pass.upgrade.starter_standard": 1000,
  "aseatawaits.pass.upgrade.standard_premium": 2000,
  "aseatawaits.pass.upgrade.starter_premium": 3000,
};

/** Maps a product id to a fresh-pass tier, or null. */
export function passTierForProduct(productId: string | undefined): EventPassTier | null {
  if (!productId) return null;
  return PASS_PRODUCT_TIER[productId] ?? null;
}

/** Maps a product id to an upgrade pair, or null. */
export function passUpgradeForProduct(productId: string | undefined): PassUpgrade | null {
  if (!productId) return null;
  return PASS_UPGRADE_PRODUCTS[productId] ?? null;
}

/** True for any pass-related consumable (base pass or upgrade). */
export function isPassProduct(productId: string | undefined): boolean {
  return passTierForProduct(productId) !== null || passUpgradeForProduct(productId) !== null;
}

/** Amount paid in cents from a verified transaction. The App Store signs
 * `price` in milliunits of `currency` (e.g. $9.99 → 9990); falls back to the
 * catalog price when absent. */
export function paidCents(price: number | undefined | null, fallbackCents: number): number {
  if (typeof price === "number" && price > 0) return Math.round(price / 10);
  return fallbackCents;
}

/** Milliseconds-since-epoch → ISO string, or null. */
export function isoDate(ms: number | undefined | null): string | null {
  return typeof ms === "number" && ms > 0 ? new Date(ms).toISOString() : null;
}

/** Introductory free-trial offer type in App Store payloads. */
export const OFFER_TYPE_INTRODUCTORY = 1;
