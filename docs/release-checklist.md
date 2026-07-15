# Loom — TestFlight / App Store submission checklist

State as of 2026-07-15 (v1.3.0, build 4). Checked items below were verified
against the current working tree. Unchecked items require a human, App Store
Connect / Google Cloud access, an archive, or a physical-device pass.

## Verified in the current repository

- [x] App and widget `Info.plist`, entitlements, privacy manifests, and the
      Xcode project pass `plutil -lint`.
- [x] The app and widget privacy manifests are included in their respective
      Resources build phases.
- [x] App and widget entitlements use the same App Group as `SharedStore`:
      `group.com.christoforakis.Loom`.
- [x] The app targets both iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`),
      with portrait and both landscape orientations enabled for iPad.
- [x] The work-session Live Activity now has an interactive pause/resume
      `LiveActivityIntent`, session-scoped App Group state, 44-point controls,
      accessibility labels, and task deep links. This still needs the physical
      device verification listed below.
- [x] Custom Settings switches expose native labeled switch semantics and use
      at least 44-point interaction targets without replacing the Hearth style.
- [x] Tasks, Settings, and Weave use centered readable-width content on iPad;
      the custom bottom bar is capped while Schedule retains the wider canvas.
- [x] Onboarding is scroll-safe for short windows and large text, honors Reduce
      Motion, and offers “Use recommended defaults” without removing the full
      four-step setup.
- [x] Final rebuilt simulator bundle passed **102/102 unit tests** on
      2026-07-15. The five main UI regressions passed **5/5 on a 13-inch iPad**;
      on iPhone, all four applicable tests passed and the iPad-only case was
      skipped as designed. Coverage includes iPad landscape navigation, native
      Settings switch semantics, task capture/navigation, full onboarding, and
      the recommended-defaults escape.
- [x] A fresh unsigned generic-device Release build and Xcode static-analysis
      pass both completed with no diagnostics on the final working tree.
- [x] Urgency red now maintains at least 4.68:1 contrast against Loom's lightest
      dark card surface, clearing normal-text contrast guidance.
- [x] `ITSAppUsesNonExemptEncryption = NO` is declared in the app plist.

## Blockers — do before submitting

- [ ] **Choose a unique app name.** “Loom” is not available. Confirm the new
      name in App Store Connect and with an appropriate trademark search, then
      update user-facing app, widget, notification, export, onboarding, and
      calendar copy consistently. Do not rename the bundle IDs, App Group, or
      persistent-store identifiers as part of a cosmetic rebrand. Calendar
      migration must continue recognizing existing calendars named “Loom.”
- [ ] **Publish live Support and Privacy Policy URLs.** Enter both working URLs
      in App Store Connect. Do not submit placeholder, private, or redirect-only
      pages. The privacy policy should cover on-device storage, speech input,
      Apple/Google Calendar access, retention/deletion, and revocation.
- [ ] **Add the Privacy Policy link inside the app.** As of this audit,
      Settings → About only exposes Version and data export; App Review
      Guideline 5.1.1 also requires an easily accessible in-app policy link.
- [ ] **Archive with Xcode 26 or later and the iOS 26 SDK or later.** This has
      been required for App Store uploads since April 28, 2026. Confirm the SDK
      in Organizer's archive/build metadata; the project file's compatibility
      version and `SDKROOT = auto` do not prove which SDK built the archive.
- [ ] **Google OAuth consent screen**: in Google Cloud Console, confirm the
      OAuth consent screen is **published** (not "Testing") and, if Google
      flags the `calendar.events` scope as sensitive, that verification is
      complete. In Testing mode only allow-listed accounts can sign in. Supply
      App Review with a working demo account or precise review instructions for
      the optional integration.
- [ ] **App Privacy label** (App Store Connect → App Privacy): answer
      accurately for the submitted binary and published policy. The current
      code audit supports **"Data Not Collected"** — data is local SwiftData,
      Google Calendar calls act on the user's account, and no Loom backend,
      analytics, ads, tracking, or third-party SDKs were found — but verify the
      archive privacy report and App Store Connect definitions before attesting.
- [ ] **Age rating questionnaire**: answer for the exact submitted product and
      marketing copy. Do not assume 4+ if the listing frames Loom as ADHD or
      health/wellness support; use the rating App Store Connect derives from
      the truthful answers.
- [ ] **Capture required screenshots**: current iPhone screenshots plus the
      required **13-inch iPad** set because the app ships natively to iPad.
      Review iPad composition rather than merely scaling the phone layout.
- [ ] **Physical-device capability pass**: install an archive-signed build and
      verify the shared SwiftData store/App Group across the app and widget,
      widget refresh, Live Activity start/deep link/pause/resume/end from the
      Lock Screen and Dynamic Island, local notifications, speech, and Calendar
      permissions. Confirm App Group provisioning for both bundle identifiers.
- [ ] **Export compliance**: already answered in code
      (`ITSAppUsesNonExemptEncryption = NO`) — TestFlight should not ask.
      If Connect still asks, answer "standard encryption only / exempt."

## App Store Connect metadata

- [ ] Unique app name, subtitle, and description (name and subtitle are each
      limited to 30 characters). The README's feature list is a strong draft;
      avoid claiming anything not in the submitted build.
- [ ] Keywords, category (Productivity).
- [ ] **Support URL** (required) and marketing URL (optional); verify the
      deployed pages load without authentication.
- [ ] **Privacy policy URL** (required even with "Data Not Collected"), matching
      the in-app link and actual submitted behavior.
- [ ] Screenshots: 6.9" iPhone required; **iPad 13" also required because the
      app ships to iPad** (`TARGETED_DEVICE_FAMILY = 1,2`). Take iPad
      screenshots seriously — reviewers test on iPad (Guideline 2.4.1).
- [ ] Age rating questionnaire, using the derived rating from truthful answers
      rather than targeting a predetermined rating.

## App Review notes (paste into "Notes for Review")

- Google Calendar sync is optional; the app is fully usable without it.
  If review needs a Google account to test sync, provide a demo account
  (Guideline 2.1 — demo credentials for any feature behind a login).
- Microphone/speech is used only for dictating a task in the capture sheet.
- The Live Activity's inline pause/resume control intentionally changes only
  the current work-session timer and does not open the app.

## Recommended device pass before TestFlight

- [ ] One VoiceOver walk-through of the Tasks tab + capture sheet.
- [ ] One run at the largest accessibility Dynamic Type size.
- [ ] One iPad session (portrait + landscape, plus narrow and short resizable
      windows) touching all four tabs.
- [ ] One physical-device App Group/widget/Live Activity pass, including pause
      and resume while the app is backgrounded and the screen is locked.
- [ ] Launch from a cold start — should now open on the dark Hearthlight
      background (no white flash).

## Deliberate decisions (documented so nobody "fixes" them)

- **No Sign in with Apple**: not required — Google OAuth is a data
  integration, not an account system (Guideline 4.8 does not apply).
- **Dark-only appearance**: locked via `.preferredColorScheme(.dark)`;
  consistent and HIG-acceptable as a deliberate design.
- **Optional onboarding**: the 4-step flow requests no permissions, existing
  users bypass it, and first-time users can choose “Use recommended defaults”
  without completing every page.

## Follow-ups worth considering (not release-gating)

- Digest notifications (morning preview / evening wrap-up) default ON behind
  one permission grant; consider making them opt-in from Settings.
- Cap the deadline date picker (e.g. two years out) so pathological far-future
  deadlines can't slow the day-by-day slot search.
- Live Activity pause/resume via App Intents is implemented; keep its physical
  device and archive-signed verification as a release gate until it passes.
