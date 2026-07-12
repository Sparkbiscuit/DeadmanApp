# Loom — TestFlight / App Store submission checklist

State as of 2026-07-11 (v1.3.0, build 4). Code-side compliance work is done on
branch `claude/ui-bugs-google-calendar-rmi1tz`; the items below are the ones
only a human with App Store Connect / Google Cloud access can finish.

## Blockers — do before submitting

- [ ] **Google OAuth consent screen**: in Google Cloud Console, confirm the
      OAuth consent screen is **published** (not "Testing") and, if Google
      flags the `calendar.events` scope as sensitive, that verification is
      complete. In Testing mode only allow-listed accounts can sign in — App
      Review's account would hit a dead end, which is a rejection.
- [ ] **App Privacy label** (App Store Connect → App Privacy): answer
      **"Data Not Collected."** Everything is local SwiftData; the only network
      traffic is the user's own Google Calendar calls. There is no Loom
      backend, no analytics, no third-party SDKs.
- [ ] **Export compliance**: already answered in code
      (`ITSAppUsesNonExemptEncryption = NO`) — TestFlight should not ask.
      If Connect still asks, answer "standard encryption only / exempt."

## App Store Connect metadata

- [ ] App name, subtitle, description. The README's feature list is a strong
      draft; avoid claiming anything not in the build.
- [ ] Keywords, category (Productivity).
- [ ] **Support URL** (required) and marketing URL (optional). A simple page
      at christoforakis.com works.
- [ ] **Privacy policy URL** (required even with "Data Not Collected").
      One page: data stays on device, Google Calendar access is user-initiated
      and revocable, no data sold/shared.
- [ ] Screenshots: 6.9" iPhone required; **iPad 13" also required because the
      app ships to iPad** (`TARGETED_DEVICE_FAMILY = 1,2`). Take iPad
      screenshots seriously — reviewers test on iPad (Guideline 2.4.1).
- [ ] Age rating questionnaire (should land at 4+).

## App Review notes (paste into "Notes for Review")

- Google Calendar sync is optional; the app is fully usable without it.
  If review needs a Google account to test sync, provide a demo account
  (Guideline 2.1 — demo credentials for any feature behind a login).
- Microphone/speech is used only for dictating a task in the capture sheet.

## Recommended device pass before TestFlight

- [ ] One VoiceOver walk-through of the Tasks tab + capture sheet.
- [ ] One run at the largest accessibility Dynamic Type size.
- [ ] One iPad session (portrait + landscape) touching all four tabs.
- [ ] Launch from a cold start — should now open on the dark Hearthlight
      background (no white flash).

## Deliberate decisions (documented so nobody "fixes" them)

- **No Sign in with Apple**: not required — Google OAuth is a data
  integration, not an account system (Guideline 4.8 does not apply).
- **Dark-only appearance**: locked via `.preferredColorScheme(.dark)`;
  consistent and HIG-acceptable as a deliberate design.
- **Onboarding not skippable**: 4 short steps, requests no permissions,
  existing users bypass it. Fine as is.
- **`try!` in LoomApp.swift's in-memory fallback container**: accepted risk;
  it is the last resort after the disk store fails and cannot realistically
  throw.

## Follow-ups worth considering (not release-gating)

- Digest notifications (morning preview / evening wrap-up) default ON behind
  one permission grant; consider making them opt-in from Settings.
- `loomRed` as body text measures ~4.3:1 contrast (just under 4.5:1);
  consider a lighter `loomRedDisplay` token for on-dark text.
- Cap the deadline date picker (e.g. two years out) so pathological far-future
  deadlines can't slow the day-by-day slot search.
- Live Activity could get a real interactive pause button via App Intents
  (iOS 17+) instead of the current open-the-app tap.
