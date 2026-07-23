# Task: Migrate the iOS app to the July 2026 pricing model (Event Passes + Pro)

You are working in the iOS repo at `/Users/bricefoster/Documents/iOS_Applications/A Seat Awaits` (SwiftUI, iOS 18, StoreKit 2, no third-party dependencies — a custom `SupabaseClient` actor talks directly to Supabase). The web app at `/Users/bricefoster/Documents/Applications/a-seat-awaits` already implements the new model and is the source of truth; read `shared/billing/plans.ts` there before writing any Swift.

## The new model (already live in staging backend)

Consumer subscriptions are replaced by **one-time Event Passes**, and the subscription lineup collapses to a **single "Pro" subscription** (internal plan id stays `elite` — it is only relabeled).

**Event Passes** (one-time purchase, one pass per event):

| Tier | Price | Guest cap | AI import | Collaborators | Export/print | Event sharing |
|---|---|---|---|---|---|---|
| Starter | $9.99 | 50 | no | 0 | yes | no |
| Standard | $19.99 | 150 | yes (20 lifetime imports per event) | 0 | yes | no |
| Premium | $39.99 | 500 | yes (50 lifetime imports per event) | 2 | yes | yes |

**Pro subscription** (internal id `elite`): $49/mo, $490/yr — 100 events, 1,000 guests/event, 5 collaborators/event, all features. It is the ONLY subscription still sold.

**Legacy plans** `core`, `basic` (displayed "Essentials"), `pro` (displayed "Signature") are grandfathered: existing subscribers keep them, restores must still work, but they must not be purchasable. Display names come from `PLAN_DISPLAY_NAMES` in the web repo's `shared/billing/plans.ts`: `basic→Essentials`, `pro→Signature`, `elite→Pro`. Never confuse internal id `pro` (legacy Signature) with the marketed "Pro" (internal `elite`).

**Hard policy decisions — do not revisit:**
- **Passes NEVER expire.** Only a refund revokes one (`refunded_at` set → inactive). An earlier "event date + 90 days" expiry design was explicitly rejected and reverted; do not reintroduce any expiry machinery, warning emails, or date-required-at-purchase logic. Marketing copy is "your pass never expires."
- **No free tier and no trial for new users.** Remove the introductory free-trial offers from the products that remain on sale.
- Abuse is bounded by caps, not expiry: guest caps per tier, and a lifetime AI-import cap per pass (20 Standard / 50 Premium), enforced server-side.

## Backend contract (already exists — do not redesign it)

The `event_passes` table exists in the **staging** Supabase project (`zpqjbnwtntnuixhtayve` — the one `Config/Secrets.Development.plist` points at). Prod (`ivjqqoaumqjmnzwckzfb`) does NOT have it yet; develop and test against staging. Table shape (see web repo migrations `20260703090000_event_passes.sql`, `20260704110000_pass_never_expires_ai_cap.sql`, `20260704140000_pass_first_purchase.sql`):

- `id uuid PK`, `event_id uuid NULL UNIQUE` (FK events; **NULL = unattached pass**, bought before the event exists), `user_id uuid`, `tier event_pass_tier ('starter'|'standard'|'premium')`, `guest_cap int`, `amount_paid_cents int`, `currency text default 'usd'`, **`provider text CHECK IN ('stripe','apple')`**, `stripe_payment_intent_id`, `stripe_checkout_session_id UNIQUE`, **`apple_transaction_id text UNIQUE`** (reserved for this migration), `purchased_at`, `refunded_at NULL`, `ai_imports_used int default 0`, timestamps.
- RLS: users can SELECT their own rows only. All writes are service-role (edge functions).
- `event_has_active_pass(event_id)` = a non-refunded row exists. `increment_pass_ai_imports(event_id)` is service-role only.
- **Event creation is enforced by a DB trigger** (`enforce_event_creation_entitlement`, AFTER INSERT on `events`): it (1) auto-claims the buyer's oldest unattached pass and attaches it to the new event, else (2) allows if there's an active/trialing paid subscription or `users.legacy_free = true`, else (3) raises `EVENT_PASS_REQUIRED: ...`. The iOS app must handle that error string from event inserts by showing the pass paywall.
- The `ai-import-guests` edge function (web repo `supabase/functions/ai-import-guests/`) already does all pass/subscription entitlement + AI-cap enforcement server-side. No iOS gating change needed for AI import beyond error messaging (new denial code: `pass_ai_cap_reached`).
- The web app's Nuxt routes (`/api/billing/*`) are NOT available to iOS. iOS computes its gate client-side from Supabase directly: its own `event_passes` rows (RLS), its `subscriptions` row, and `users.legacy_free` — with the DB trigger as the real enforcement.

## Current iOS state (verified map — start here)

- **Product catalog:** `A Seat Awaits/Models/AppleProducts.swift` — 8 auto-renewable products `aseatawaits.sub.{core,essentials,signature,elite}.{monthly,annual}` in group "A Seat Awaits Plans". TS mirror in `supabase/functions/_shared/apple.ts` (`PRODUCT_PLAN` map) — the two must stay in sync.
- **StoreKit manager:** `A Seat Awaits/Services/SubscriptionStore.swift` — StoreKit 2, purchases with `.appAccountToken(userUUID)`, posts `transaction.jwsRepresentation` to the `apple-iap-sync` edge function, and calls `transaction.finish()` only after a 2xx. Server-authoritative; never unlocks optimistically. Preserve this pattern for passes.
- **Paywall:** `A Seat Awaits/Features/Account/PaywallView.swift` — currently shows all 4 paid tiers with monthly/annual picker and a 14-day-trial CTA. Hides purchase UI when `hasActiveStripeBilling` (guideline 3.1.1) — keep that behavior.
- **Plan gating:** `A Seat Awaits/Models/PlanPolicy.swift` (hard-coded per-tier `PlanLimits`, `PlanTier.normalize` maps basic→essentials, pro→signature) and `A Seat Awaits/Models/CollaborationPlanPolicy.swift` (enforced in `Services/EventCollaboratorsStore.swift`). Export gate in `Features/Account/GuestListExportView.swift`. Guest/event counts are display-only (server enforces).
- **Backend models:** `A Seat Awaits/Models/AccountModels.swift` (`SubscriptionRow`, `AccountSnapshot`, `BillingProvider`), `Models/UserProfile.swift` (no `legacy_free` yet — add it).
- **Edge functions in this repo:** `supabase/functions/apple-iap-sync/` (verifies JWS via `@apple/app-store-server-library`, checks `appAccountToken == user.id`, 409s if live Stripe billing, upserts `subscriptions` keyed on `user_id`) and `supabase/functions/apple-webhook/` (App Store Server Notifications V2, idempotent via `apple_notification_log`). Subscriptions-only today — no consumable path exists.
- **StoreKit test config:** `Config/Products.storekit`, wired only to the `A Seat Awaits Dev` scheme. The `products` (consumables) array is empty today.

## Work to do

### 1. StoreKit products
- Add three **consumable** products: `aseatawaits.pass.starter` ($9.99), `aseatawaits.pass.standard` ($19.99), `aseatawaits.pass.premium` ($39.99). Consumable — not non-consumable — because a user buys one pass per event, repeatedly.
- Add three **upgrade consumables** for pay-the-difference in-place upgrades (StoreKit cannot charge an arbitrary delta like Stripe does): `aseatawaits.pass.upgrade.starter-standard` ($10), `aseatawaits.pass.upgrade.standard-premium` ($20), `aseatawaits.pass.upgrade.starter-premium` ($30). These match `passUpgradePrice()` in the web repo. An upgrade purchase bumps the existing pass row's `tier`/`guest_cap` and adds to `amount_paid_cents` (mirror `handlePassCheckoutCompleted` in the web repo's `server/api/stripe/webhook.post.ts`).
- Keep all 8 legacy subscription product IDs defined in code (restores and webhook mapping must keep working), but only `elite` monthly/annual remain purchasable, relabeled **"Pro"**. Remove the introductory offers from the elite products in `Config/Products.storekit` (and note that the same must be done in App Store Connect — flag it in your final report, don't attempt ASC changes).
- Update `Config/Products.storekit` with the new consumables so the Dev scheme can test end-to-end.

### 2. Swift model layer
- Extend `AppleProducts.swift` (or a sibling `PassProducts.swift`) with the pass/upgrade product IDs and a `PassTier` enum (`starter|standard|premium`) with price, guest cap, AI-import flag + lifetime cap, collaborator count, and display copy matching the table above.
- Add an `EventPass` model mirroring `event_passes` (RLS lets the user select their own rows). Key derived value: `isActive == (refundedAt == nil)`.
- Rewrite `PlanPolicy.swift`: entitlement is now **per-event** — an event is entitled by an active pass on it OR the account's entitled subscription. Keep `PlanTier`/legacy limits intact for grandfathered subscribers, add the pass-based path, and route all display names through one mapping (`elite` → "Pro", `basic` → "Essentials", `pro` → "Signature"). Update `CollaborationPlanPolicy.swift`: Premium pass → 2 collaborators, `elite` sub → 5, legacy `pro`(Signature) → 2.
- Add `legacyFree` (`legacy_free`) to `UserProfile.swift` and its fetch in `Services/AccountStore.swift`; fetch the user's passes alongside the subscription in `AccountSnapshot`.

### 3. Purchase flow (new `PassStore` or extension of `SubscriptionStore`)
- Same server-authoritative pattern as today: purchase with `.appAccountToken`, POST the JWS to a new edge function, `transaction.finish()` **only after 2xx**. This matters even more for consumables — an unfinished consumable is redelivered via `Transaction.updates`, which is your retry mechanism; finishing before the server records it would lose the purchase.
- Support buying a pass **for a specific event** (send `eventId`) and **unattached** (no event yet — the DB trigger attaches it at event creation). The purchase request body should be `{ jws, eventId? }`.
- Upgrade flow: only offered when the target tier outranks the event's current pass tier; send the event id and expect the server to mutate the existing row.

### 4. Backend: new/updated edge functions (in this repo's `supabase/functions/`, deploy to staging)
- **`apple-pass-sync`** (new, modeled on `apple-iap-sync`): verify JWS, require `appAccountToken == user.id`, then for a pass product insert into `event_passes` `{ user_id, tier, guest_cap, amount_paid_cents (from transaction price), currency, provider: 'apple', apple_transaction_id: transaction.transactionId, event_id: eventId ?? null }`, idempotent on the unique `apple_transaction_id` (treat unique-violation as success). For an upgrade product: validate the event's current pass, then update `tier`, `guest_cap`, `amount_paid_cents += paid`. Reject upgrade products whose from-tier doesn't match the event's current pass.
- **`apple-webhook`**: extend to handle notifications for one-time products — on `REFUND`/`REVOKE` for a pass product, set `refunded_at = now()` on the matching `apple_transaction_id`. On `CONSUMPTION_REQUEST`, note that the web repo already has the usage-snapshot logic in `server/api/admin/pass-usage.get.ts` (policy: unused passes are refundable, no questions asked) — wire a consumption response later if time allows, otherwise log and flag it.
- Update `supabase/functions/_shared/apple.ts` to know the new product IDs (pass tiers + upgrades) alongside `PRODUCT_PLAN`.

### 5. UI
- **Paywall rework** (`PaywallView.swift`): passes become the primary offer — three pass cards (Standard highlighted) with a single Pro subscription option beneath ("for planners running many events"). Remove Core/Essentials/Signature cards and all trial copy. Keep `product.displayPrice` (never hard-code prices), keep the Stripe-billing hide rule, keep restore purchases.
- **Event creation gate**: before opening the create-event flow, check (in order) unattached active pass → entitled subscription → `legacyFree`; if none, present the pass paywall. Also catch the `EVENT_PASS_REQUIRED` error from the insert as the authoritative backstop. When an unattached pass gets consumed, refresh local pass state.
- **Per-event UI**: surface the event's pass (tier, guest cap, AI imports used vs cap) and an upgrade entry point; gate collaboration/export/sharing per the event's pass tier or the subscription, whichever grants more.
- Update `SubscriptionSummaryView` / `ManageAccountView` to show owned passes (attached + unattached) alongside the subscription, and `GuestListExportView` / `EventCollaboratorsView` gates to accept pass-based entitlement.

### 6. Constraints
- Never remove legacy product IDs, plan mappings, or enum values — grandfathered subscribers depend on them.
- Do not add expiry logic of any kind to passes.
- Don't optimistically unlock anything client-side; the server snapshot is the truth.
- The client gate is UX; the DB trigger and edge functions are enforcement. Don't duplicate cap enforcement (guest counts, AI caps) in Swift beyond display and friendly errors.
- Match existing code style: `@Observable` stores, actor-based `SupabaseClient`, no new dependencies.

### 7. Verify before finishing
- Build both schemes; run the test target.
- Using the Dev scheme + `Config/Products.storekit` + StoreKit testing in Xcode against **staging** Supabase: buy each pass tier (attached and unattached), create an event that auto-claims an unattached pass, hit the create-event gate with zero entitlements and see the paywall, perform an in-place upgrade, simulate a refund (StoreKit testing → refund) and confirm the pass deactivates via the webhook path, buy the Pro subscription, and restore purchases.
- Confirm a simulated legacy subscriber (e.g. a `basic` row in staging) still sees "Essentials" and keeps their limits, with no purchase path back to it.

### 8. Report at the end
- Anything that must be done in App Store Connect by hand (create the 6 consumables, remove intro offers, remove legacy products from sale) — list exact product IDs and prices.
- Any deploy commands run against staging, and a reminder that **prod Supabase does not have the `event_passes` migration yet** — nothing here should be pointed at prod.
- Open questions you deferred rather than guessed.
