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

Environment-specific config lives in `A Seat Awaits/Secrets.plist`, which is
**git-ignored**. Copy the template and fill in real values:

```bash
cp "A Seat Awaits/Secrets.example.plist" "A Seat Awaits/Secrets.plist"
```

Set:

- `SUPABASE_URL` – your Supabase project URL (e.g. `https://<ref>.supabase.co`)
- `SUPABASE_ANON_KEY` – the project's **public** anon key (never the service key)

If `Secrets.plist` is missing or still has placeholders, the app shows a
"Configuration needed" screen explaining what to do.

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
