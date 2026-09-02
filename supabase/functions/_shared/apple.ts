// Apple App Store verification + product mapping for the IAP edge functions.
//
// Every App Store-signed payload (transaction JWS from the app, notification
// from Apple) is verified against Apple's pinned root certificate before
// anything is trusted. The sole exception is the explicitly enabled Xcode
// staging path described below. The Apple Root CA G3 certificate is fetched
// from apple.com once per isolate and cached; no binary blobs live in source.
//
// Environments: production accepts Production AND Sandbox (TestFlight builds
// produce Sandbox-signed transactions while talking to the production
// backend). A staging deployment may explicitly add Xcode so the Dev scheme's
// local StoreKit configuration can exercise the full server write path.
//
// IMPORTANT: signature verification is intentionally skipped for
// Environment.XCODE because those transactions are generated locally rather
// than signed by the App Store. Never add Xcode to a production deployment's
// APPLE_ACCEPT_ENVIRONMENTS value.

import "npm:reflect-metadata@0.2.2";
import {
  BasicConstraintsExtension,
  X509Certificate,
  cryptoProvider,
} from "npm:@peculiar/x509@2.0.0";

import { optionalEnv } from "./env.ts";

const APPLE_ROOT_CA_URL = "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer";
const DEFAULT_BUNDLE_ID = "heartlineeventsolutionsllc.A-Seat-Awaits";
const APPLE_LEAF_OID = "1.2.840.113635.100.6.11.1";
const APPLE_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";
const CERTIFICATE_DATE_SKEW_MS = 60_000;

// Apple's Node server library delegates certificate validation to
// node:crypto.X509Certificate. Supabase Edge Runtime exposes that class, but
// several operations used by the library (`toString`, `raw`, `verify`, and
// `publicKey`) are not implemented. Peculiar X509 performs the same checks on
// the WebCrypto API that Supabase supports.
cryptoProvider.set(crypto);

export enum Environment {
  XCODE = "Xcode",
  SANDBOX = "Sandbox",
  PRODUCTION = "Production",
}

export interface JWSTransactionDecodedPayload {
  appAccountToken?: string;
  bundleId?: string;
  currency?: string;
  environment?: string;
  expiresDate?: number;
  offerType?: number;
  originalTransactionId?: string;
  price?: number;
  productId?: string;
  purchaseDate?: number;
  revocationDate?: number;
  signedDate?: number;
  transactionId?: string;
  [key: string]: unknown;
}

export interface JWSRenewalInfoDecodedPayload {
  autoRenewProductId?: string;
  autoRenewStatus?: number;
  environment?: string;
  gracePeriodExpiresDate?: number;
  signedDate?: number;
  [key: string]: unknown;
}

interface NotificationData {
  appAppleId?: number;
  bundleId?: string;
  environment?: string;
  signedRenewalInfo?: string;
  signedTransactionInfo?: string;
  [key: string]: unknown;
}

interface NotificationIdentity {
  appAppleId?: number;
  bundleId?: string;
  environment?: string;
  [key: string]: unknown;
}

interface ExternalPurchaseTokenIdentity extends NotificationIdentity {
  externalPurchaseId?: string;
}

export interface ResponseBodyV2DecodedPayload {
  appData?: NotificationIdentity;
  data?: NotificationData;
  externalPurchaseToken?: ExternalPurchaseTokenIdentity;
  notificationType?: string;
  notificationUUID?: string;
  signedDate?: number;
  subtype?: string;
  summary?: NotificationIdentity;
  [key: string]: unknown;
}

enum VerificationStatus {
  VERIFICATION_FAILURE = 1,
  INVALID_APP_IDENTIFIER = 3,
  INVALID_ENVIRONMENT = 4,
  INVALID_CHAIN_LENGTH = 5,
  INVALID_CERTIFICATE = 6,
  MALFORMED_PAYLOAD = 7,
}

class AppleVerificationError extends Error {
  readonly status: VerificationStatus;
  override readonly cause?: Error;

  constructor(status: VerificationStatus, message: string, cause?: unknown) {
    super(message);
    this.name = "AppleVerificationError";
    this.status = status;
    this.cause = cause instanceof Error ? cause : undefined;
  }
}

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
      if (s === "xcode") return [Environment.XCODE];
      return [];
    });
}

let cachedRoot: X509Certificate | null = null;

async function appleRootCertificate(): Promise<X509Certificate> {
  if (cachedRoot) return cachedRoot;
  const res = await fetch(APPLE_ROOT_CA_URL);
  if (!res.ok) throw new Error(`Failed to fetch Apple root certificate (${res.status})`);
  try {
    cachedRoot = new X509Certificate(await res.arrayBuffer());
    return cachedRoot;
  } catch (err) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_CERTIFICATE,
      "Apple root certificate could not be parsed",
      err,
    );
  }
}

function productionAppAppleId(): number {
  const appAppleIdRaw = optionalEnv("APPLE_APP_APPLE_ID");
  const appAppleId = appAppleIdRaw ? Number(appAppleIdRaw) : NaN;
  if (!Number.isSafeInteger(appAppleId) || appAppleId <= 0) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_APP_IDENTIFIER,
      "APPLE_APP_APPLE_ID must be the numeric App Store app id",
    );
  }
  return appAppleId;
}

function decodeBase64(value: string, urlSafe: boolean): Uint8Array<ArrayBuffer> {
  const pattern = urlSafe ? /^[A-Za-z0-9_-]+$/ : /^[A-Za-z0-9+/]+={0,2}$/;
  if (!value || !pattern.test(value)) {
    throw new AppleVerificationError(
      VerificationStatus.MALFORMED_PAYLOAD,
      "Signed payload contains invalid base64 data",
    );
  }
  const normalized = (urlSafe ? value.replace(/-/g, "+").replace(/_/g, "/") : value)
    .replace(/=+$/, "");
  if (normalized.length % 4 === 1) {
    throw new AppleVerificationError(
      VerificationStatus.MALFORMED_PAYLOAD,
      "Signed payload contains invalid base64 data",
    );
  }
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }
    return bytes;
  } catch (err) {
    throw new AppleVerificationError(
      VerificationStatus.MALFORMED_PAYLOAD,
      "Signed payload contains invalid base64 data",
      err,
    );
  }
}

function decodeJsonSegment(segment: string): Record<string, unknown> {
  try {
    const value = JSON.parse(new TextDecoder().decode(decodeBase64(segment, true)));
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Expected object");
    return value as Record<string, unknown>;
  } catch (err) {
    if (err instanceof AppleVerificationError) throw err;
    throw new AppleVerificationError(
      VerificationStatus.MALFORMED_PAYLOAD,
      "Signed payload is not valid JSON",
      err,
    );
  }
}

function certificateDateIsValid(certificate: X509Certificate, effectiveDate: Date): boolean {
  const time = effectiveDate.getTime();
  return Number.isFinite(time) &&
    certificate.notBefore.getTime() <= time + CERTIFICATE_DATE_SKEW_MS &&
    certificate.notAfter.getTime() >= time - CERTIFICATE_DATE_SKEW_MS;
}

async function verifyCertificateChain(
  leaf: X509Certificate,
  intermediate: X509Certificate,
  effectiveDate: Date,
): Promise<CryptoKey> {
  const root = await appleRootCertificate();
  const intermediateConstraints = intermediate.getExtension(BasicConstraintsExtension);
  const chainMatches = intermediate.issuer === root.subject && leaf.issuer === intermediate.subject;
  const extensionsMatch = leaf.getExtension(APPLE_LEAF_OID) !== null &&
    intermediate.getExtension(APPLE_INTERMEDIATE_OID) !== null &&
    intermediateConstraints?.ca === true;
  const datesMatch = certificateDateIsValid(leaf, effectiveDate) &&
    certificateDateIsValid(intermediate, effectiveDate) &&
    certificateDateIsValid(root, effectiveDate);

  let signaturesMatch = false;
  try {
    signaturesMatch = await intermediate.verify({ publicKey: root.publicKey, signatureOnly: true }, crypto) &&
      await leaf.verify({ publicKey: intermediate.publicKey, signatureOnly: true }, crypto);
  } catch (err) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_CERTIFICATE,
      "Apple certificate signatures could not be checked",
      err,
    );
  }

  if (!chainMatches || !extensionsMatch || !datesMatch || !signaturesMatch) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_CERTIFICATE,
      "Apple certificate chain is invalid",
    );
  }

  try {
    return await leaf.publicKey.export(
      { name: "ECDSA", namedCurve: "P-256" },
      ["verify"],
      crypto,
    );
  } catch (err) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_CERTIFICATE,
      "Apple signing key could not be imported",
      err,
    );
  }
}

async function verifyAndDecodeJws<T extends Record<string, unknown>>(
  jws: string,
  environment: Environment,
): Promise<T> {
  const parts = jws.split(".");
  if (parts.length !== 3 || parts.some((part) => !part)) {
    throw new AppleVerificationError(
      VerificationStatus.MALFORMED_PAYLOAD,
      "Signed payload must contain three JWS segments",
    );
  }

  const payload = decodeJsonSegment(parts[1]) as T;

  // Xcode StoreKit files are locally generated and aren't signed by Apple.
  // Only authenticated sync endpoints may opt into this staging-only path.
  if (environment === Environment.XCODE) return payload;

  const header = decodeJsonSegment(parts[0]);
  if (header.alg !== "ES256") {
    throw new AppleVerificationError(
      VerificationStatus.VERIFICATION_FAILURE,
      "Signed payload does not use ES256",
    );
  }
  if (!Array.isArray(header.x5c) || header.x5c.length !== 3 ||
      !header.x5c.every((entry) => typeof entry === "string")) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_CHAIN_LENGTH,
      "Signed payload must contain Apple's three-certificate chain",
    );
  }

  let leaf: X509Certificate;
  let intermediate: X509Certificate;
  try {
    leaf = new X509Certificate(decodeBase64(header.x5c[0] as string, false));
    intermediate = new X509Certificate(decodeBase64(header.x5c[1] as string, false));
  } catch (err) {
    if (err instanceof AppleVerificationError) throw err;
    throw new AppleVerificationError(
      VerificationStatus.INVALID_CERTIFICATE,
      "Apple certificate chain could not be parsed",
      err,
    );
  }

  const signedDate = typeof payload.signedDate === "number" ? payload.signedDate : Date.now();
  const publicKey = await verifyCertificateChain(leaf, intermediate, new Date(signedDate));
  const signature = decodeBase64(parts[2], true);
  if (signature.byteLength !== 64) {
    throw new AppleVerificationError(
      VerificationStatus.VERIFICATION_FAILURE,
      "Signed payload has an invalid ES256 signature",
    );
  }

  let signatureMatches = false;
  try {
    signatureMatches = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      signature,
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`),
    );
  } catch (err) {
    throw new AppleVerificationError(
      VerificationStatus.VERIFICATION_FAILURE,
      "Apple JWS signature could not be checked",
      err,
    );
  }
  if (!signatureMatches) {
    throw new AppleVerificationError(
      VerificationStatus.VERIFICATION_FAILURE,
      "Apple JWS signature is invalid",
    );
  }
  return payload;
}

/** Tries each accepted environment until one verifies the payload. */
async function verifyAcrossEnvironments<T>(
  verify: (environment: Environment) => Promise<T>,
  allowXcode: boolean,
): Promise<{ payload: T; environment: Environment }> {
  let lastError: unknown = new Error("No accepted App Store environments configured");
  for (const environment of acceptedEnvironments()) {
    if (environment === Environment.XCODE && !allowXcode) continue;
    try {
      if (environment === Environment.PRODUCTION) productionAppAppleId();
      return { payload: await verify(environment), environment };
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
    async (expectedEnvironment) => {
      const transaction = await verifyAndDecodeJws<JWSTransactionDecodedPayload>(jws, expectedEnvironment);
      if (transaction.bundleId !== appleBundleId()) {
        throw new AppleVerificationError(
          VerificationStatus.INVALID_APP_IDENTIFIER,
          "Transaction bundle id does not match this app",
        );
      }
      if (transaction.environment !== expectedEnvironment) {
        throw new AppleVerificationError(
          VerificationStatus.INVALID_ENVIRONMENT,
          "Transaction environment is not accepted",
        );
      }
      return transaction;
    },
    true,
  );
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
    async (expectedEnvironment) => {
      const payload = await verifyAndDecodeJws<ResponseBodyV2DecodedPayload>(
        signedPayload,
        expectedEnvironment,
      );
      let identity: NotificationIdentity | undefined = payload.data ?? payload.summary ?? payload.appData;
      if (payload.externalPurchaseToken) {
        const external = payload.externalPurchaseToken;
        identity = {
          ...external,
          environment: external.externalPurchaseId?.startsWith("SANDBOX")
            ? Environment.SANDBOX
            : Environment.PRODUCTION,
        };
      }
      if (identity?.bundleId !== appleBundleId()) {
        throw new AppleVerificationError(
          VerificationStatus.INVALID_APP_IDENTIFIER,
          "Notification bundle id does not match this app",
        );
      }
      if (expectedEnvironment === Environment.PRODUCTION &&
          identity.appAppleId !== productionAppAppleId()) {
        throw new AppleVerificationError(
          VerificationStatus.INVALID_APP_IDENTIFIER,
          "Notification App Store app id does not match this app",
        );
      }
      if (identity.environment !== expectedEnvironment) {
        throw new AppleVerificationError(
          VerificationStatus.INVALID_ENVIRONMENT,
          "Notification environment is not accepted",
        );
      }
      return payload;
    },
    false,
  );
  const data = notification.data;
  const transaction = data?.signedTransactionInfo
    ? await verifyAndDecodeJws<JWSTransactionDecodedPayload>(data.signedTransactionInfo, environment)
    : null;
  const renewalInfo = data?.signedRenewalInfo
    ? await verifyAndDecodeJws<JWSRenewalInfoDecodedPayload>(data.signedRenewalInfo, environment)
    : null;
  if (transaction && (transaction.bundleId !== appleBundleId() || transaction.environment !== environment)) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_APP_IDENTIFIER,
      "Nested transaction does not match this app",
    );
  }
  if (renewalInfo && renewalInfo.environment !== environment) {
    throw new AppleVerificationError(
      VerificationStatus.INVALID_ENVIRONMENT,
      "Nested renewal environment is not accepted",
    );
  }
  return { notification, transaction, renewalInfo, environment };
}

export function environmentLabel(environment: Environment): "Sandbox" | "Production" {
  // Xcode transactions exist only in staging and are recorded as Sandbox so
  // the canonical DB audit column retains its production/sandbox vocabulary.
  return environment === Environment.PRODUCTION ? "Production" : "Sandbox";
}

/** Privacy-safe verifier details for function logs. Apple's
 * VerificationException has an empty message, so String(error) alone normally
 * logs only "Error" and hides the useful status/cause. */
export function verificationErrorDetails(err: unknown): Record<string, unknown> {
  if (!err || typeof err !== "object") return { err: String(err).slice(0, 160) };
  const value = err as { name?: unknown; message?: unknown; status?: unknown; cause?: unknown };
  const cause = value.cause;
  const causeText = cause instanceof Error ? cause.message : cause == null ? "" : String(cause);
  return {
    err: typeof value.message === "string" && value.message
      ? value.message.slice(0, 160)
      : String(value.name ?? "Error").slice(0, 80),
    verificationStatus: typeof value.status === "number" ? value.status : undefined,
    cause: causeText ? causeText.slice(0, 160) : undefined,
  };
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
