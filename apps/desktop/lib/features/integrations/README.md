# Integrations ownership

The application constructs `IntegrationsController` from separate host,
navigation, operation, dialog, preference, meeting-fact, meeting-command and
onboarding ports. Other features import `ports.dart`; they receive account and
recording facts without receiving the account client, connected-sources writer,
or another feature's controller.

| Library | Owner and purpose |
| --- | --- |
| `integrations_controller.dart` | Integrations actions and shell rebuild bridge |
| `ports.dart` | Outward facts and commands consumed by other features |
| `preferences.dart` | Immutable prepared values and owned typed preference watches |
| `audio_access.dart` | Immutable audio capability command replies |
| `widgets.dart` | Device controls, confirmation/input dialogs, display labels and shortcut binding |
| `desktop_settings.dart` | Login items and application entries |
| `global_shortcuts.dart`, `hypr_shortcuts.dart` | Shortcut registration and injected Hyprland effects |
| `google_picker.dart`, `google_sign_in_dialog.dart` | Drive selection and route-owned sign-in |
| `system_audio_setup_dialog.dart` | Audio access request, refresh and permission guidance |

`DesktopEnvironment`, the shell ports, `DesktopVisuals` and request identity are
shared dependencies. Account button and approval presentation remain composition
owned. Feature extraction does not move their state into Integrations.

The preference model owns four stable `StoreReadQueries.preference` watches.
Ordinary data revisions refresh those queries through the reader; status-only
changes do not recreate subscriptions. Only current results publish. Equal
prepared values do not notify. Replacing the client session or workspace clears
prepared values, retires old callbacks and binds new watches. The default values
preserve the initial controls while their first snapshots load. Action inputs
use fresh typed reads, including shortcut installation before initial watches.
Device and keyboard builders perform no persistence admissions.

The controller closes its preference model, account, command socket and global
shortcuts once. The shell remains responsible for workspace connection lifetime
and its pending note-save drain. Actions retain the global operation gate and
their tab, meeting, preview, connection, session and epoch checks. Dialog input
controllers remain alive until their own departing routes have unmounted.

Audio capability replies are separate from F3 live capture status. Google
provider, availability and sync facts use F3 `GooglePresentation`; configure
relies on the service's status-before-reply ordering and never changes the
connection-owned snapshot.
