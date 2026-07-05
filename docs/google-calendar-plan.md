# Google Calendar two-way sync — scoped plan (target: v1.2)

Deliberately shipped separately from v1.1.0: unlike Apple Calendar (EventKit,
no credentials), Google requires an OAuth client that only the project owner
can create, and every part of the flow needs on-device testing with real
credentials.

## What you (Nick) need to provision first

1. Google Cloud Console → create a project → enable **Google Calendar API**.
2. Credentials → **OAuth client ID**, type **iOS**, bundle ID
   `com.christoforakis.Loom`.
3. Note the client ID (`xxxx.apps.googleusercontent.com`) and its reversed
   form — the reversed ID becomes a URL scheme in Loom's Info.plist.
4. OAuth consent screen: External, scope `https://www.googleapis.com/auth/calendar.events`,
   add your own Google account as a test user (no verification needed for
   personal use).

Paste the client ID into the session (or commit it to a config file) and the
implementation can proceed.

## Implementation outline

- **Auth (no SDK, no backend):** `ASWebAuthenticationSession` + PKCE against
  `accounts.google.com/o/oauth2/v2/auth`; token exchange and refresh against
  `oauth2.googleapis.com/token` via URLSession. Access + refresh tokens stored
  in the **Keychain** (`kSecClassGenericPassword`, service `com.christoforakis.Loom.google`) —
  this Keychain wrapper becomes the shared pattern for any future OAuth
  integration.
- **Import (Google → Loom):** `events.list` on the primary calendar, polled on
  app foreground (same hook as Apple import), using `syncToken` for
  incremental updates and falling back to a full window fetch on 410. Events
  land as `BusyEvent(source: .googleCalendar)` — the same lightweight busy
  model as Apple import: they occupy scheduler slots, appear on the schedule,
  and never become tasks. Upsert on event ID; deletions honored via
  `showDeleted=true` in incremental responses.
- **Export (Loom → Google):** opt-in toggle, off by default; nothing is pushed
  to a calendar the user hasn't enabled. `events.insert` for new
  ScheduledBlocks, `events.update` on time changes, `events.delete` on block
  removal, keyed by a `googleEventId` stored on ScheduledBlock (mirrors
  `appleCalendarEventId`). Reconciled after every scheduling change, same call
  sites as the Apple export.
- **Loop guard:** exported Loom events carry an extended property
  (`private.loom=1`) and are excluded from import.
- **Settings UI:** "Google Calendar" section — Connect/Disconnect (shows the
  signed-in account), import toggle, export toggle. Disconnect wipes Keychain
  tokens and Google-sourced BusyEvents.
- **Failure handling:** refresh-token expiry surfaces as a "Reconnect Google"
  banner; network errors fail silently on foreground polls (next poll
  retries).

## Test plan

Unit: token refresh state machine, syncToken pagination/410 fallback, upsert/
delete reconciliation (mock URLProtocol). Device: full OAuth round-trip,
import of a busy event, export + edit + delete round-trip, disconnect.
