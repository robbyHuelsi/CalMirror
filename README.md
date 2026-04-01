# CalMirror — Architecture Overview

CalMirror is a native iOS/macOS app built with Swift and SwiftUI that mirrors calendar events from Apple's Calendar app to a CalDAV server. It operates with **read-only access** to the user's calendars — events are never modified locally.

---

## Key Features

| Feature | Description |
|---------|-------------|
| **Read-Only Guarantee** | The `EKEventStore` is wrapped in a `ReadOnlyEventStore` that only exposes read methods. The store instance is `private` and never leaked — the compiler prevents any write calls. |
| **Smart Change Detection** | Each event is hashed (SHA256) by its content (title, dates, location, notes, recurrence). Only actual changes trigger a server update. |
| **Flexible Prefix System** | Per-calendar toggleable prefix that prepends text to event titles on the remote server (e.g. `[Work] Meeting`). Defaults to the calendar name when enabled. |
| **Event-Driven Sync** | Reacts instantly to `EKEventStoreChanged` notifications with 5-second debouncing, plus a configurable periodic fallback timer. |
| **Background Sync (iOS)** | Uses `BGAppRefreshTask` via SwiftUI's `.backgroundTask` modifier for sync while the app is in the background. |
| **Secure Credentials** | Server passwords are stored in the system Keychain, never in SwiftData or UserDefaults. |
| **Universal App** | Runs on both iOS and macOS from a single codebase using platform-adaptive SwiftUI. |

---

## Project Structure

```
CalMirror/
├── CalMirrorApp.swift              App entry point, dependency wiring
├── ContentView.swift               Main dashboard UI
├── Info.plist                      Permissions & background task config
│
├── Models/
│   ├── CachedEvent.swift           SwiftData cache for synced events
│   ├── CalendarSyncConfig.swift    Per-calendar sync & prefix settings
│   └── ServerConfiguration.swift   CalDAV server connection settings
│
├── Services/
│   ├── ReadOnlyEventStore.swift    Read-only wrapper around EKEventStore
│   ├── CalDAVClient.swift          HTTP client for CalDAV (PUT/DELETE/PROPFIND)
│   ├── ICSGenerator.swift          EKEvent → RFC 5545 iCalendar conversion
│   ├── SyncEngine.swift            Core sync orchestration logic
│   └── SyncScheduler.swift         Timing: notifications, timer, background tasks
│
├── Views/
│   ├── ServerSettingsView.swift    Server URL, auth, path, interval config
│   ├── CalendarSelectionView.swift Calendar picker with prefix controls
│   └── SyncLogView.swift           Sync history with status indicators
│
└── Utilities/
    └── KeychainHelper.swift        Secure password storage via Security framework
```

---

## File Responsibilities

### App Layer

| File | Role |
|------|------|
| `CalMirrorApp.swift` | Creates the `ReadOnlyEventStore` → `SyncEngine` → `SyncScheduler` chain. Sets up SwiftData container with all three models. Registers iOS background task. Injects dependencies via `@State` and `.environment()`. |
| `ContentView.swift` | Dashboard showing sync status, event count, server info. Provides manual sync button and navigation to all settings views. Listens for `calendarDidChange` and `scheduledSyncDidFire` notifications to trigger auto-sync. |

### Models (SwiftData)

| File | Role |
|------|------|
| `CachedEvent.swift` | Mirrors each synced event. Stores the `eventIdentifier` (from EventKit), `remoteUID` (on CalDAV), and a `contentHash` (SHA256). The hash is computed from title + dates + location + notes + isAllDay + recurrence. Used for change detection without re-uploading unchanged events. |
| `CalendarSyncConfig.swift` | One record per calendar. Tracks whether sync is enabled, whether a prefix is active, and the custom prefix text. `effectivePrefix` returns the resolved prefix (custom text → calendar name → nil). |
| `ServerConfiguration.swift` | Single active server config. Stores URL, username, calendar path, sync interval. Password is stored separately in Keychain referenced by `keychainServiceID`. Generates the full `calendarCollectionURL` for CalDAV operations. |

### Services

| File | Role |
|------|------|
| `ReadOnlyEventStore.swift` | Defines the `EventReading` protocol (read-only contract). Implements it by wrapping a `private` `EKEventStore`. Exposes: `requestAccess()`, `availableCalendars()`, `fetchEvents()`, `calendar(withIdentifier:)`, and an `AsyncStream<Void>` for change notifications. Thread-safe via `NSLock`. |
| `CalDAVClient.swift` | Swift `actor` for thread-safe CalDAV HTTP operations. `putEvent()` sends `PUT /{path}/{uid}.ics` with iCalendar body. `deleteEvent()` sends `DELETE`. `testConnection()` sends `PROPFIND` with depth 0. Uses Basic Auth. Handles HTTP status codes and wraps errors in `CalDAVError`. |
| `ICSGenerator.swift` | Pure function `generateICS(from:uid:prefix:)`. Converts an `EKEvent` to a full `VCALENDAR/VEVENT` string per RFC 5545. Handles all-day events, timed events, recurrence rules (RRULE), availability/transparency, and proper text escaping (`\n`, `\;`, `\,`). Applies the prefix as `[Prefix] Title`. |
| `SyncEngine.swift` | `@Observable @MainActor` class. `performSync(modelContext:)` runs the full sync in 11 steps: load config → load calendars → fetch EventKit events → fetch SwiftData cache → compare hashes → PUT new/changed events → DELETE removed events → save cache. Returns a `SyncResult` with counts and errors. Prevents concurrent syncs via `isSyncing`. |
| `SyncScheduler.swift` | `@Observable @MainActor` class. `start()` launches two concurrent `Task`s: one listening to `EKEventStoreChanged` (debounced 5s), one firing a periodic timer. Both post `Notification`s so the UI can trigger sync with its `ModelContext`. Also provides `triggerSync()` for manual use. |

### Views

| File | Role |
|------|------|
| `ServerSettingsView.swift` | Form with fields for server URL, display name, username, password (SecureField), calendar path (with example hint), and sync interval picker (15/30/60/120 min). "Test Connection" button calls `CalDAVClient.testConnection()` and shows green/red feedback. Saves to SwiftData + Keychain. |
| `CalendarSelectionView.swift` | Requests calendar access if needed. Lists all device calendars grouped by source (iCloud, Google, etc.) with colored dots. Per-calendar: sync toggle, prefix toggle, custom prefix text field, live preview (`[Work] Event Title`). Creates `CalendarSyncConfig` records on-demand. |
| `SyncLogView.swift` | Displays a reverse-chronological list of `SyncResult` entries. Each row shows: success/error icon, relative timestamp, counts (created in green, updated in blue, deleted in red), and any error messages. |

### Utilities

| File | Role |
|------|------|
| `KeychainHelper.swift` | Static methods `save(password:service:account:)`, `load(service:account:)`, `delete(service:account:)`. Uses `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlock`. Handles duplicates by deleting before insert. |

---

## Program Flow

### 1. App Launch

```
CalMirrorApp.init()
  └─▶ Creates ReadOnlyEventStore
  └─▶ Creates SyncEngine(eventStore:)
  └─▶ Creates SyncScheduler(eventStore:, syncEngine:)

CalMirrorApp.body
  └─▶ Injects SyncScheduler into environment
  └─▶ .task { startScheduler() }
        └─▶ Reads sync interval from ServerConfiguration
        └─▶ Calls syncScheduler.start(intervalMinutes:)
              ├─▶ Starts EKEventStoreChanged listener (AsyncStream)
              └─▶ Starts periodic timer Task
```

### 2. Sync Trigger (any of three paths)

```
┌─ Calendar change detected (EKEventStoreChanged, debounced 5s)
├─ Periodic timer fires
└─ User taps "Sync Now"
         │
         ▼
ContentView receives Notification / button tap
         │
         ▼
syncScheduler.triggerSync(modelContext:)
         │
         ▼
syncEngine.performSync(modelContext:)
```

### 3. Sync Execution

```
performSync()
  │
  ├─ 1. Fetch active ServerConfiguration from SwiftData
  ├─ 2. Load password from Keychain
  ├─ 3. Fetch enabled CalendarSyncConfigs from SwiftData
  ├─ 4. Resolve EKCalendar objects via ReadOnlyEventStore
  ├─ 5. Build prefix map (calendarId → prefix string)
  ├─ 6. Fetch events from EventKit (past 1 month → future 6 months)
  ├─ 7. Fetch CachedEvents from SwiftData
  ├─ 8. Create CalDAVClient with server credentials
  │
  ├─ 9. For each current event:
  │     ├─ New? → ICSGenerator.generateICS() → CalDAVClient.putEvent() → insert CachedEvent
  │     ├─ Changed? (hash differs) → regenerate ICS → putEvent() → update CachedEvent
  │     └─ Unchanged? → skip
  │
  ├─ 10. For each cached event no longer in EventKit or disabled calendar:
  │      └─ CalDAVClient.deleteEvent() → delete CachedEvent
  │
  └─ 11. Save SwiftData context → return SyncResult
```

### 4. CalDAV Server Communication

```
CalDAVClient (actor)
  │
  ├─ PUT /{calendarPath}/{uid}.ics
  │   Headers: Content-Type: text/calendar, Authorization: Basic ...
  │   Body: VCALENDAR/VEVENT (generated by ICSGenerator)
  │
  ├─ DELETE /{calendarPath}/{uid}.ics
  │   (404 is treated as success — already gone)
  │
  └─ PROPFIND / (Depth: 0)
      Used for connection testing
```

---

## Change Detection Strategy

Instead of re-uploading all events on every sync, CalMirror uses content hashing:

```
SHA256( title | startDate | endDate | location | notes | isAllDay | recurrenceRule )
```

- On first sync: all events are new → all are uploaded, hashes are cached
- On subsequent syncs: only events whose hash differs from the cached value are re-uploaded
- Deleted events (present in cache but absent from EventKit) are removed from the server

This minimizes network traffic and server load.

---

## Security Model

| Concern | Approach |
|---------|----------|
| Calendar writes | Impossible — `EKEventStore` is `private` inside `ReadOnlyEventStore`, only `EventReading` protocol methods are exposed |
| Password storage | Keychain with `kSecAttrAccessibleAfterFirstUnlock` — never stored in SwiftData, UserDefaults, or plaintext |
| Server auth | Basic Auth over HTTPS (URLSession enforces ATS by default) |
| Concurrent access | `CalDAVClient` is an `actor`; `ReadOnlyEventStore` uses `NSLock`; `SyncEngine` prevents concurrent syncs |
