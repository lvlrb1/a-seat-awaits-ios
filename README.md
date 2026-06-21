# A Seat Awaits — iOS

Native SwiftUI app for the **A Seat Awaits** seating-chart & guest-list product.
It connects directly to the same Supabase backend the web app uses (GoTrue auth
+ PostgREST data, protected by row-level security), so no server secrets ship in
the app — only the public anon key.

## Requirements

- **Xcode 27** (the project uses object format 110 / iOS 27 SDK). On this machine
  that is `/Applications/Xcode-beta.app`.
- An iOS 27 simulator (e.g. *iPhone 17 Pro*).

## Configuration (required before first run)

The app has two environments selected by the build configuration:

| Scheme | Config | Environment | Bundle id | Supabase |
| --- | --- | --- | --- | --- |
| **A Seat Awaits Dev** | Debug | Development | `heartlineeventsolutionsllc.A-Seat-Awaits.dev` | staging project |
| **A Seat Awaits** | Release | Production | `heartlineeventsolutionsllc.A-Seat-Awaits` | production project |

Per-environment config lives in the top-level `Config/` folder (outside the
app's synchronized source folder) and is **git-ignored**. Copy each template
and fill in real values:

```bash
cp Config/Secrets.Development.example.plist Config/Secrets.Development.plist
cp Config/Secrets.Production.example.plist  Config/Secrets.Production.plist
```

Set in each file:

- `SUPABASE_URL` – the environment's Supabase project URL (`https://<ref>.supabase.co`)
- `SUPABASE_ANON_KEY` – the project's **public** anon key (never the service key)
- `PUBLIC_SITE_URL` – origin for guest-facing share links (staging for dev, `https://aseatawaits.com` for prod)

At build time the **Embed Environment Secrets** build phase copies the file
named by the active configuration's `SECRETS_FILE` setting
(`Config/Development.xcconfig` / `Config/Production.xcconfig`) into the app
bundle as `Secrets.plist`, which `AppConfig` reads at runtime. If the required
file is missing the build **fails** with a clear message — a Release build never
falls back to development values.

The anon key is a public client credential; row-level security (RLS) is the
security boundary. Never put a service-role key, Stripe secret, or any server
credential in these files.

## Open & run

```bash
open "A Seat Awaits.xcodeproj"   # opens in the default Xcode — use Xcode 27
```

In Xcode: select the **A Seat Awaits** scheme + an **iOS 27** simulator and press
**⌘R**. Run tests with **⌘U**.

From the command line:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -project "A Seat Awaits.xcodeproj" -scheme "A Seat Awaits" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' test
```

## Architecture

| Layer | Files |
|---|---|
| Config | `Config/AppConfig.swift` (loads `Secrets.plist`) |
| Networking | `Networking/SupabaseClient.swift` (actor: GoTrue auth + PostgREST over URLSession), `KeychainStore`, `SupabaseError` |
| Models | `Models/` — `Event`, `Guest`, `SeatingTable`, `GuestGroup`, `AuthSession`, `UserProfile` |
| Business logic | `Models/SeatingLogic.swift` — filtering, sorting, stats, capacity (unit-tested) |
| State / services | `Services/` — `AppState`, `EventStore`, `SeatingStore` (`@Observable`, `@MainActor`) |
| UI | `Features/` — Auth (splash + sign up/in + Apple), Events, Seating (Guests/Tables workspace, floor plan), Find Your Table, Account |
| Theme | `Theme/Theme.swift` — brand palette (`#43204f`), hero/orb background, cards |

### Notes

- **Sign in with Apple** is wired (button + nonce + Supabase `id_token` grant).
  To enable end-to-end, add the "Sign in with Apple" capability to the target
  and enable the Apple provider in Supabase. Email/password works out of the box.
- **Billing** (plan upgrades) is handled on the web via Stripe; the Account
  screen reflects the user's tier and links out to manage billing.
- Subscription/usage limits are enforced server-side by the web API; the app
  talks to Supabase directly, so those limits are not re-enforced client-side.
