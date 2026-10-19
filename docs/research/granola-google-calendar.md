# Granola Google Calendar connection analysis

Granola 7.663.2 routes Google calendar authentication and event refreshes through Granola services. In the running app, the work Google account is selected under **Visible calendars**, and **Create events** is **Enabled**. Those settings establish the connection presented by the client; they do not independently establish the current Google consent scopes or whether a new write would succeed.

Observed on 19 October 2026. Worktree: `/Users/blackmyth/src/open-foresight-granola-calendar`, branch `research/granola-google-calendar`, starting at `b62e5e0`. The initial tracing pass changed no application code or dependency builds. The follow-up report records the later implementation and validation.

Follow-up: the [JavaScript and live redirect trace](granola-javascript-auth-trace.md) establishes the actual WorkOS/Google redirect route, requested scopes for identity/read/write flows, desktop callback and session handling, and a concrete Foresight replication design. It supersedes the original scope uncertainty below.

## Google connection flow

The shipped client contains these connected operations:

1. **Sign in with Google.** `authUrls-D4hR6tns.js` builds a URL using Granola's `auth` endpoint and `provider=google`. Desktop sign-in generates an S256 PKCE challenge and includes `code_challenge`, platform, client version, and a sign-in correlation ID. Calendar permissions can be requested in this authentication flow. [S01, S17]
2. **Link a calendar to an existing session.** The calendar connection UI calls `calendar-link-auth` with the current Granola session token. It receives a provider and `redirectUrl`, then opens that URL. The completion handler submits the returned code to `calendar-link-auth-complete`; the deep-link handling code can also supply the stored PKCE verifier. Successful completion triggers a calendar refresh. This is a distinct path from initial sign-in. [S05, S14]
3. **Refresh meetings through Granola.** The refresh caller invokes the API export `Zr`, which resolves to `wo`, which calls `refresh-calendar-events`. The shared request function defaults to POST and adds `Authorization: Bearer <Granola session token>`. This inspected path requests events from Granola, rather than constructing a Google Calendar REST request locally. [S03, S04, S07]
4. **Filter and store returned events.** The refresh code consumes `results.events`, `results.calendars`, and `results.error`. It filters cancelled events and events lacking timed start/end values or a summary, sorts the remaining events, updates calendar state, and calls the event persistence function. That function upserts returned events by ID and removes stale non-EventKit rows. The client defines a `calendar_events` table with `id`, `start_time`, `end_time`, and JSON `data`; refresh logic also reads that table and can update existing notes from their linked calendar event. [S06, S07, S13, S18]

The client/backend boundary is directly visible in the shipped JavaScript. Granola's backend accessing Google on behalf of the connected user is the resulting architectural inference. The backend implementation and Google-side requests were not captured.

| Operation | Shipped endpoint mapping |
| --- | --- |
| Initial authentication | `https://api.granola.ai/v1/auth` |
| Start calendar linking | `https://pecan.api.granola.ai/v1/calendar-link-auth` |
| Complete calendar linking | `https://cinnamon.api.granola.ai/v1/calendar-link-auth-complete` |
| Refresh calendar events | `https://api.granola.ai/v1/refresh-calendar-events` |
| Read selected calendars and permission status | `get-selected-calendars` |
| Change calendar selection | `set-selected-calendar` |

These are packaged mappings, not a live network capture. Endpoint mapping excerpts are retained as S15 and S16.

## Your enabled event creation permission

The Calendar settings component displays the **Create events** permission section only when the backend's `enabled_calendars` includes `google`. It displays **Enabled** when the backend reports `calendar_write` as true. The observed UI therefore corroborates a Google connection with event creation permission reported by Granola. [S08, S09, U01]

The grant-access hook builds a Google authentication URL with `request_calendar_permissions=true`, `in_app_calendar_linking=true`, and `calendar_write_linking=true`. It then polls `get-selected-calendars` until `calendar_write` becomes true. This explains how the write permission status reaches the UI. These flags describe Granola's request to its authentication service; they are not exact Google OAuth scope strings. [S02, S10]

## Separate Apple Calendar path

The app also ships `Resources/native/eventkit.node`. Its main-process loader resolves native modules under `process.resourcesPath/native`, and an EventKit utility process calls `getAuthorizationStatus()` and `getEvents({startTimeMs,endTimeMs})`. It converts those results into the common calendar event shape with `eventkit:` IDs. Its default date window is one day before now through fourteen days after now. [S11, S12]

IDA Pro 9.3 and Hex-Rays decompiled the arm64 slice of this module:

| Function | Address in the extracted arm64 image | Observed behavior |
| --- | --- | --- |
| `GetAuthorizationStatus` | `0xe8c` | Native calendar authorization wrapper |
| `RequestAccess` | `0x1040` | Calls `requestFullAccessToEventsWithCompletion:` on macOS 14+, with a legacy `requestAccessToEntityType:completion:` branch |
| `GetCalendars` | `0x13f8` | Native calendar enumeration wrapper |
| `GetEvents` | `0x1b4c` | Builds `predicateForEventsWithStartDate:endDate:calendars:` and calls `eventsMatchingPredicate:` |

The EventKit module explains access to calendars synchronized into macOS. It is separate from the Google linking and refresh path traced above. The current UI evidence supports the Google connection; it does not establish that the optional Apple Calendar feature is enabled.

## Evidence and coverage

Local evidence is retained under [`.granola-analysis`](../../.granola-analysis/). That directory is ignored by Git and contains extracted application code, analysis databases, logs, and the following records:

| Record | Purpose |
| --- | --- |
| `identity.json` | App identity, original ASAR/native hashes, arm64 derivative hash, and eleven verified ASAR members |
| `calendar-code-excerpts.json` | S01–S18, exact shipped text with member paths and half-open Unicode code point offsets |
| `ui-observation.json` | U01, the selected work calendar and enabled event creation status; no settings were changed |
| `calendar-scope-evidence.json` | REA analysis of five exact calendar-related files; five parsed files, zero parse failures, partial application coverage |
| `auth-trace-evidence.json` | REA trace seeded at the calendar write URL export; one matched seed, partial graph coverage |
| `ida-eventkit.json` and `eventkit.i64` | Native function inventory, string references, decompiler output, and reusable IDA database |
| `collect_evidence.py` | Rechecks extracted bytes against the ASAR and regenerates identities and excerpts |

REA application Evidence: `ev_e348d36bd1a3ea1396615a174375f03f39b2c3139d4e0be1cb8d60678a713cfe`.

REA authentication export trace Evidence: `ev_e90422beabd081e5c3df94497731d16a159fffb0f55fd6bfcaba8084ff0b7d65`.

The generic `refresh-calendar-events` string seed did not match a REA graph entity (`ev_d27fa5c151cd573b612efec260f6cb4e1a03d382ed467e6cc83e945926efdf31`). The refresh call chain above comes from direct inspection of the function body and import/export aliases, rather than a claimed graph trace. REA's export trace is structural and does not prove runtime invocation.

The original ASAR SHA-256 is `17046e95777b85a211b1e6676ac86bd5835c30b51928051411a796017a1302b9`. The original universal EventKit module SHA-256 is `3ff550b713d8883bcf7df6a807a96f76df54b8f8f83159937499b9b6ded4e996`.

REA found an integrity mismatch in the unpacked extended-attribute library. Analysis continued as requested. Each of the eleven JavaScript members used here independently matches its ASAR integrity declaration, and `codesign --verify --deep --strict` passed for the installed app. Neither check proves vendor intent or backend behavior.

Hopper's REA launcher failed because macOS denied Apple Events access; IDA provided the native decompilation. The existing Hopper `Granola.hop` document was left intact. The full-ASAR CLI analysis exhausted Node's approximately 4 GiB heap and exited 134; its failed output is preserved in `application-analysis.stderr`. The successful five-file analysis is deliberately bounded and leaves omitted imports unresolved.

## Remaining questions

The client connection mechanism, selected work calendar, reported write permission, local event cache, and separate EventKit path are answered within the evidence above. The follow-up trace resolves the scopes requested by fresh hosted authentication flows; the user's historical grant, Google refresh-token custody and encryption, server-side synchronization cadence or webhooks, and Workspace administrator policy remain unresolved. During this initial tracing pass no user sign-in or consent was completed, no events were created, and no credential files were read. See the follow-up report for the later user-confirmed sign-in.
