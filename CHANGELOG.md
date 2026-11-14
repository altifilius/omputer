# Changelog

## Documentation privacy — November 14

- Remove workstation-specific network addresses, listener/client port records, device-routing/access-rule details and private filesystem locations from public documentation.
- Describe local IPC without publishing its filesystem endpoint or credential paths. Runtime code, connection behavior and security checks are unchanged.
- Preserve existing signed commits. This cleanup changes the current documentation, not earlier Git history or copies already downloaded.

## Android 1.3.1 (22) — selectable palettes and neumorphic theme selector

- Add Adaçayı, Okyanus, Orman, Gece mavisi, Vişne, Kiremit and Mercan from the supplied palettes, each with light and dark appearances. Preserve original Omputer as the default and restorable theme.
- Give each light theme distinct base, raised, inset, highlight and shadow roles instead of a shared near-white blend. Keep semantic text/action contrast and the existing material geometry.
- Add Settings → Görünüm → Renk teması with named native radio choices and exact five-color strips. Use the shared raised/inset native button for disclosure and recess the selected row; retain keyboard focus and bounded expanded-state semantics.
- Persist palette and appearance independently through native storage. Keep the Home sun/moon control in place, preserve the previous choice on failed storage and cache theme data by palette/brightness.

Scoped analysis and 25 distinct targeted scenarios passed across serial gates; no full-suite claim. Physical-phone review covered all seven light materials, light/dark selector states, collapse/reopen selection and real process-restart persistence. The signed update preserved existing pairing and application data. Full TalkBack, performance and network acceptance remain unclaimed. Local reports, screenshots and generated APKs are not included in source publication. See [verification](VERIFICATION.md#november-14--android-131-selectable-palettes-and-neumorphic-selector).

## PC 0.3.0 / Android 1.3.0 (21) / bridge 1.2.0 — local controls and queued prompts

- Queue normal phone prompts through terminal-compatible streaming admission; preserve images and literal text. Reject dropped prompts instead of reporting false acceptance.
- Export actual local administration, modes and lifecycle controls from pinned OMP 18.20.0. Keep hosted sharing/collaboration unavailable.
- Add typed phone settings/account/skill screens, preserve command arguments, and require exact catalog/writer identity plus explicit mutation confirmation.
- Keep protected input and private authorization context outside durable drafts, operations and journals; require a visible gesture for browser opening.
- Report missing resume roots/sources honestly. Relocate only to an explicitly selected registered project, preserving original journal bytes and single-writer ownership.
- Pin the compiled Bun template to private 1.4.4, validate all bootstrap targets before merging, and verify resource archives before promotion.

Scoped runtime/bridge/Rust/Flutter/Kotlin gates and a compiled-runtime integration smoke passed during implementation. Physical-device rendering/gesture acceptance used a separate memory-only adapter; it does not certify production model/networking or Android FLAG_SECURE. PC activation remains a separate safe-update step; existing hosts are never hot-patched or force-closed. Concurrent palette/theme work, local reports, screenshots and generated packages are not part of this source commit.

## Bridge 1.1.2 — HTML-form questions from terminal OMP

- Route modern terminal `formDialog` asks through OMP's canonical field walker while the local bridge is connected, using existing Inbox select/input/editor interactions. Preserve original form behavior offline and leave managed RPC unchanged.
- Keep HTML parsing, submitted values, constraints, defaults, Other and multi-selection in the host runtime; no HTML renderer, remote resources or new phone permissions.
- Restore the original optional form surface on teardown and disconnect. Already-loaded terminal extensions require a normal safe `/restart` or close/resume; conversation reload alone does not reload code.

Ten targeted bridge/lifecycle tests passed. Real installed OMP18.20.0 AskTool preserved a radio value and numeric input; a separate real-socket physical-phone round trip returned `{"delivery":"received"}` to the same host AskTool. Android APK and daemon binary were not rebuilt for the installed bridge hotfix. Whole-form preview/option notes are intentionally not available in the canonical field-by-field route.

## Android 1.2.10 (19) — larger Sisyphus before project names

- Move the working project-card GIF from the continuation preview's trailing edge to the start of the heading, enlarged from40dp to64dp with12dp before the project name.
- Let continuation text use a full-width row below. Preserve wrapping title, native pin, session-row indicators, real-work/motion gates, idle navigation and direct bottom join.

Scoped analyzer clean; 30 targeted card/avatar/carousel scenarios passed. Original-signed 1.2.10 installed on the authorized Samsung; installed APK and dist match, first-install and pairing preserved. Physical dark/light heading and GIF motion inspected; app errors empty. Source publication includes the related 1.2.8–1.2.10 Android changes; no full-suite rerun or PC/bridge change. Local acceptance record: `Raporlar/2026-11-13-sisyphus-baslik-yerlesimi.md` (not included in source publication).

## Android 1.2.9 (18) — direct body and bottom-tab join

- Remove the separate8dp gap and12dp full-width connector band above bottom navigation; the selected tab opens directly into the matching content without a closing line/shadow.
- Apply the same join to Projects and Inbox, including active filter tints. Preserve the inset session-reading panel, existing selected-tab/concave-shoulder form, fixed navigation and native safe area.
- Keep New session as a separate action/route; project cards, work GIF, idle behavior, Live filtering and data boundaries unchanged.

Scoped analysis and62distinct targeted scenarios passed earlier; no suite rerun for physical delivery. Same original-signed production1.2.9APK installed on authorized Samsung, matching dist/pulled-base hash and preserving first-install/pairing. Actual dark/light join pixels, real workingGIF, finite idle/manual/end navigation, separate form/Back, supplied icon and empty composer/native Samsung IME verified; app errors empty, font/density/theme preserved. No source defect, new build, provider submission or PC/bridge activation. Local acceptance record: `Raporlar/2026-11-13-alt-menu-tek-govde.md` (not included in source publication).

## Android 1.2.8 (17) — Sisyphus identity and idle project navigation

- Use the supplied Sisyphus image for Android launcher/splash with adaptive and monochrome assets; animate the supplied local GIF only while work is actually running.
- Raise the foreground project card above neutral back layers, enlarge names and show recorded continuation previews instead of goal/status/count stacks.
- Remove Play/Pause/Restart; begin slow finite card steps after seven idle seconds, interrupt on input, restart full dwell after release and stop at the last project.
- Replace light-theme brown action roles with dark-scheme navy; preserve dark amber, native theme controls and contrast pairs.
- Canlı aggregates only connected running/background sessions across all projects with project names; Tümü and detail keep history. Human-waiting, settled, unbridged and disconnected sessions are not live work.

Scoped analysis clean;100distinct scenarios passed across focused runs, not full suite. Exact original-signed production APK accepted on owned Android35x86_64 emulator: launcher/cold-start icon, actualGIFframes, dark/light/formIME/Back, finiteidle/held-input/reduced-motion and globalLive inspected; app errors empty. Physical-phone installation was deferred at this milestone and completed in the subsequent1.2.9/1.2.10 acceptance. PC/bridge/provider untouched. Local acceptance record: `Raporlar/2026-11-13-sisyphus-ikon-ve-canli-akis.md` (not included in source publication).

## Android 1.2.7 (16) — restored layered cards and unified native materials

- Restore upright sliding upper/lower project neighbors; keep finite project rail, paused entry and selected-project complete history.
- Remove project up/down buttons, Projects heading and list/cards UI; cleanly remove the obsolete Dart/Android project-view preference flow.
- Harmonize native switch/choice/slider/menu state roles, Inbox spacing and Settings grouped surfaces with graphite/fog/amber neumorphism.
- Simplify New session: remove named connection banner and created-session shortcut; group inset inputs/model within the raised form, preserving draft/UUID/pending/offline and successful-start behavior.

Final contrast-corrected original-signed1.2.7 (16) installed on authorized Samsung; exact installed APK promoted to `dist`. Clean scoped analysis and157 distinct targeted scenarios across focused runs, not a full-suite claim. Guarded layered drag/rail/selected history, dark/light form/IME, Inbox/Settings/Back and final label/icon contrast inspected. Pairing/data/Android settings/PC/bridge preserved; no provider submission or Git publication. [Canonical report](Raporlar/2026-11-13-perspektif-kartlar-ve-birlesik-sekmeler.md#127--katmanlı-kartları-geri-alma-ve-neumorphic-hizalama).

## Android 1.2.6 (15) — selected-project Home workbench

- Replace cross-project live sessions on Home with the selected project's entire session history, exact IDs and status retained.
- Compose normal phone Home on one screen with shorter cards and an internally scrolling session panel; preserve large-text/IME access.
- Use finite full-slot vertical transitions with six-second dwell, a project-count scrub rail and explicit restart instead of unnoticed wrapping.
- Join bottom navigation upward, use an icon-only neumorphic list/cards selector, and revise the native theme switch to the supplied sun/moon/cloud/star reference.

Original-signed 1.2.6 (15) installed and accepted on the authorized Samsung; same installed APK promoted to `dist`. Scoped analysis and 108 distinct scenarios passed across targeted runs, not a new full-suite claim. Actual selected-history Home, rail/endpoints, full-slot motion, reference themes, icon selector and native Back/form navigation inspected. User chose paused startup; Play is explicit. Pairing/data/Android settings/PC/bridge preserved; no provider submission or Git publication. [Canonical report](Raporlar/2026-11-13-perspektif-kartlar-ve-birlesik-sekmeler.md#126--seçili-proje-çalışma-yüzeyi).

## Android 1.2.5 (14) — upright downward cards and wider Home

- Remove X/Y tilt and reversed rear faces; keep every card screen-parallel in one continuous top-to-bottom flow. Wrap repositioning happens only while invisible.
- Align vertical drag, up/down buttons and keyboard direction with the visual flow; retain manual pause/play, stable project identity and accessibility/visibility gates.
- Widen Home search, joined filters/panel and bottom controls with 8dp outer gutters; replace percentage card inset with 8dp inside the panel and match list spacing.

Original-signed 1.2.5 (14) installed and visually accepted on the authorized Samsung; exact installed APK promoted to `dist`. Scoped analysis and 34/34 targeted scenarios passed. Actual upright/downward front+rear motion, pause, vertical drag, wider dark/light Home/list and exact front navigation inspected. Pairing and Android settings preserved; no provider/security/PC/bridge or Git changes. [Canonical same-day report](Raporlar/2026-11-13-perspektif-kartlar-ve-birlesik-sekmeler.md).

## Android 1.2.4 (13) — large perspective ring and joined phone tabs

- Restore the user-preferred continuous perspective project ring with the current large readable foreground card,bounded neighbors and retained list alternative. Manual selection,pause/play,stable IDs and visibility/accessibility/lifecycle gates remain.
- Keep graphite/fog/amber while reducing broad working-card fills to a quiet primary blend plus explicit true-working status/avatar.
- Move pending decisions off Home into Inbox with its count. Home filters Tümü/Canlı/Sabitlenen and bottom Projects/New session/Inbox use native joined top-rounded/concave-shoulder tabs sharing the local panel surface.
- Move theme to top left,center Omputer/connection state and place Settings top right with native Back. New session is a bottom action opening its existing form,not a selected destination.

Installed and visually accepted on the authorized Samsung as original-signed 1.2.4 (13); exact installed APK promoted to `dist`. Scoped analysis and 105 distinct targeted scenarios passed across targeted runs. [Canonical report](Raporlar/2026-11-13-perspektif-kartlar-ve-birlesik-sekmeler.md). No tablet/desktop, PC/bridge/provider/security or Git changes.

## Android 1.2.3 (12) — continuity-ring application mark

- Replace the old purple stripe icon with a custom split O representing work continuity between PC and phone. Use the established graphite, amber and fog palette, with one editable SVG source.
- Wire launcher adaptive foreground/background and Android13 monochrome assets to the same geometry. Remove unused Flutter-template bitmaps. Notification small icon and static native launch reuse the mark; no behavior,permission,pairing or startup-delay changes.

Signed1.2.3(12) is installed on authorized Samsung with exact base-APK hash and preserved first-install/pairing. Actual launcher,app-info and native cold-start mark inspected;app reconnect and scoped error read passed. Mask/small-size previews and packaged adaptive/monochrome/vector resources verified. No full-suite rerun,phone themed-icon setting change,notification delivery test,tablet/desktop work or Git publication. [Canonical logo report](Raporlar/2026-11-13-telefon-logo-ve-adaptif-ikon.md).

## Android 1.2.2 (11) — phone home and appearance choices

- Compact the phone header to one Omputer title with connection status; remove the duplicate computer-name banner and greeting headline. Align the four project filters in equal columns with shared text-scaled height.
- Restore the vertical project list as default and persist list/large-card selection locally on the phone. Separate all open sessions into Canlı oturumlar with their project names; project cards no longer repeat sessions or long selected-project summaries.
- Add the requested native sun/moon/cloud/star theme switch to the header, sharing Settings' existing persisted system/light/dark state. Use theme-derived amber surfaces and explicit status for actually running/background projects and sessions.
- Enlarge and space snap project cards; retain manual selection and user-requested20-second automatic advancement with pause/play and interaction/visibility/lifecycle/accessibility gates.

Ninety distinct targeted cases passed across runs;final switch8/8 and scoped analysis clean. Signed1.2.2(11) installed on authorized Samsung with exact base-APK hash,original first-install/pairing preservation and real phone dark/light/list/cards,filter,working/live-session,persistence,empty IME and timed7/18→8/18 auto checks. Phone left dark/list with clean search and unchanged draft. No tablet/desktop or PC/bridge release,no Git publication. [Canonical plan and execution report](Raporlar/2026-11-13-telefon-ana-sayfa-ve-gorunum-plani.md).

## Android 1.2.1 (10) — manual project cards and compact turns

- Replace the automatic perspective ring with a native snapping deck: wide readable current card, next-card edge, manual swipe and previous/next. Preserve exact project selection through live updates, filtering and reordering; keyboard and accessibility selection remain immediate.
- Group assistant work between user messages into one compact ordered operation flow. Keep explicit answers/questions and legacy unclassified text readable. Hide thinking, commentary, arguments and tool output from rendering and answer copy without rewriting stored history/export.
- Match tool results by exact call ID, retain error/interrupted/length-limit/missing-result summaries while collapsed, and open a searched hidden message at its safe operation context. Apply the same projection to owned-child history; preserve answer Markdown, file links, copy and exact source references.

Scoped analyzer clean. Ninety distinct targeted scenarios passed across the initial87-pass run and three corrected-case reruns; final19compact/session cases passed after phone-native source-focus corrections. Actual phone portrait dark/light/200%-text/IME and safe-operation/source-focus screens were inspected. Signed1.2.1(10) is in `dist/omputer-android.apk`; physical phone installation remains unperformed. No tablet/desktop work, new PC/bridge release or Git publication. [Canonical revision report](Raporlar/2026-11-13-proje-kartlari-ve-kompakt-turn.md).

## Android 1.2.0 (9) — whole-application neumorphic system

- Unify dark graphite and light fog palettes, amber action/focus, dual-shadow raised surfaces, true inset inputs and quiet reading planes. Native Material controls retain callbacks, selection, semantics and permission boundaries.
- Apply the same material to navigation, projects, sessions/composer, inbox/decisions, pairing, settings/diagnostics, files/diff/context, memory/history, commands and operations. Preserve the rotating project ring and truthfully gated working avatar.
- Replace the message field's separate palette/painter with shared depth tokens. Keep system typography/scaling, 48dp minimum targets, explicit focus/pressed/disabled states, draft ownership and input/send anchoring above IME.

Analyzer clean;187 Flutter tests passed. Actual native phone dark/light/large-text/IME surfaces were inspected; independent finish review returned ship for that bounded matrix. Same-signer1.2.0(9) is installed on Samsung with exact APK hash and preserved first-install record/pairing; physical settings/inbox/exact session/empty IME acceptance passed. Tablet excluded by user; no real work/decision/permission was submitted. See [the canonical report](Raporlar/2026-11-13-butunsel-neumorphic-ui.md).

## Android 1.1.4 (8) — November 13

- Apply the requested Uiverse-inspired neumorphic treatment only to the session message editor: graphite bevel, inset soft shadows, nested 16/12dp corners and an amber keyboard-focus outline/caret. Light mode keeps theme-derived surfaces; native editing, draft/send behavior and the bottom-above-IME layout are preserved. The accessible field name remains present for populated drafts.
- Replace the home project list with a perspective rotating card ring, preserving real project data, stable identities, search/filters and selected-project session shortcuts. Drag, previous/next and play/pause controls provide explicit navigation; reduced motion and keyboard selection remain static.
- Show a native speeder avatar only for genuinely running/background project sessions on a live connection. Waiting, settled and disconnected states do not animate as work; the avatar respects reduced motion, route visibility and app lifecycle.

Signed release is installed on the physical Samsung with exact APK hash and preserved first-install record. Actual project selection/opening, running avatar and neumorphic input above the native keyboard were inspected without submitting work. The new-session action moved to the app bar after native review found its FAB covering carousel controls. Thirty-nine targeted tests plus the added small-phone control regression passed; PC/bridge and pairing are unchanged. See [the canonical UI report](Raporlar/2026-11-13-donen-projeler-ve-calisan-avatar.md) for native scope, package identity and limits.

## PC 0.2.1 / Android 1.1.3 (7) / bridge 1.1.1 — November 4

- Reserve a session/mode draft before asynchronous persistence so overlapping composers cannot submit the same work under two UUIDs. Decision drafts capture pairing identity at edit time, preventing queued old-computer answers from entering a replacement identity.
- Enforce the native per-operation byte limit after merging retained requests and new results. Pairing/forget retire buffered share navigation, and import completion/UI delivery cannot cross pairing identity; reconnect preserves navigation.
- Keep acknowledged decisions resolved across immediate transport loss. Pending replay and disconnect cancellation are atomic and cannot reopen a final answer.
- Protect connected writers, including failed turns, against delayed archive imports and stale discovery refreshes.
- Close old dialogs on phone-triggered branch/switch lifecycle events and clear the previous journal's turn error.
- Serialize local maintenance. Backups cannot release an existing update reservation; scheduled restore requires its own cancellation. Interrupted restore rollback now allows startup without a second marker-removal error.
- Ship the October 29 correctness fixes below in newly built, separately versioned packages. Flutter verification in the bounded Android build runs with one test worker; the previous concurrent timeout is not claimed as a reproduced product deadlock.

Local packages are built and signed. Android 1.1.3 (7) is installed on Samsung with same-signer/exact-APK and bounded connected-read/reconnect/native Back/IME acceptance. The production PC0.2.1/bridge1.1.1 safe-gate activation was independently verified after one restart, retaining identity, device authorization, listener configuration and saved history. The phone then showed matching installed/running components and passed reconnect without a prompt or decision submission. Broader physical acceptance remains separate; see `VERIFICATION.md` and [the activation report](Raporlar/2026-11-05-pc-aktivasyonu-ve-telefon-kabulu.md).

## October 29 correctness fixes — included in the November 4 packages

- Preserve runtime `outcome_unknown` as durable unknown, including UUID replay; repair legacy false failures without changing request identity or replaying commands.
- Retire oldest safe final Android operation records under count/byte pressure instead of permanently blocking the 1,001st command. Pending/unknown records, unapplied draft/branch effects and unsent drafts remain protected.
- Bind new-session submissions to exact durable draft revisions/operation UUIDs. Pending duplicates cannot send again; late success clears only its submitted version and exposes the created session. Delayed restoration and loading/status reflow preserve typed text and focus.
- Reconcile final operation events arriving during an active outcome read. Fence automatic/reviewed draft effects at every asynchronous and native mutation boundary; associate legacy epoch-less effects only after an authoritative UUID result.
- Chunk large bridge control outcomes losslessly with bounded socket backpressure; benign commands omit full history, oversized single outcomes report uncertainty, cached replay never re-executes effects, and interaction overflow triggers authoritative reconnect recovery.
- Persist a journal epoch across ordinary restarts and rotate it during staged same-PC restore. Native pinned bootstrap and Dart reset lower-watermark cache/history state without rotating credentials or replaying uncertain work.

At the October 29 milestone these were source-only fixes with isolated verification. They now ship in the November 4 packages above; production activation remains separate. See `VERIFICATION.md` and the canonical October 29 review/fix report.

## Android 1.1.2 (6)

- Listed each open session beneath its project on the home screen instead of exposing only one recent-session shortcut. Same-name sessions have collision-aware identity references; live updates keep established row order and search avoids duplicate rows.
- Included terminal-open, unbridged sessions in open-session discovery and filters without granting message or resume capabilities. Closed history stays in project detail and retains the recent-history shortcut when no session is open.
- Anchored the message editor and send action at the usable bottom above the Android keyboard. Ancillary composer controls scroll independently; short-screen headers are bounded and multiline input retains usable height with model metadata, attachments and large text.
- Added behavioral coverage for parallel-session navigation, read-only terminal sessions, filters, independent drafts and short/large-text keyboard layouts. See `VERIFICATION.md` for the native emulator scope and physical-device limit.
- October 29: installed 1.1.2 (6) over the existing Samsung application with the same signer; exact installed APK hash, preserved first-install record, separate session navigation and actual keyboard layout verified without sending a prompt.

## Android 1.1.1 (5)

- Kept authenticated connection bootstrap on a separate bounded worker so an unreachable PC cannot queue ahead of cached startup, local preferences or durable drafts.
- Published local readiness before reconciling uncertain command outcomes; reconciliation remains UUID-bound, GET-only and incapable of authorizing replay. The new delayed-outcome startup regression failed before the fix and passed in the 141-test Flutter run.
- Reused the existing reconnect cancellation path after verified endpoint rediscovery, cancelling the obsolete snapshot call before the replacement bootstrap. Pairing identity, exact TLS pin and generation fences are unchanged.
- Rebuilt with the original Android signing identity; PC 0.2.0 and bridge 1.1.0 are unchanged. Physical installed-build acceptance is recorded separately in `VERIFICATION.md`.
- October 21 build-only delivery: Android release rebuilt and published without analyze/lint/tests at the user's request; unchanged PC/bridge/runtime artifacts were retained. Installation and physical acceptance remain separate deferred gates.

## PC 0.2.0 / Android 1.1.0 (4) / bridge 1.1.0

- Separated stable visible session identity, journal/provider identity, bridge binding generation, writer liveness and turn/work state. Branch/navigation outcomes retain the visible session and preserve source provenance without duplicating its writer.
- Added persistent UUID operations with accepted/running/final/unknown outcomes, status/history queries and bounded correlated command output. Android saves operation identity before dispatch and reconciles delayed results without treating acceptance as completion.
- Added runtime command catalogs and structured controls for queues, tree/branch/fork, plans, goals, side questions, owned agents/jobs, models, effort and usage. Risk/confirmation, idle and stale identity/catalog gates are enforced; unsupported TUI/credential actions have no arbitrary prompt/shell fallback.
- Added bounded child-transcript pages with exact UTF-8 byte cursors, journal-entry identity, visible ownership errors and complete generated RPC clients. Native image-share notices preserve the reading route and typed composer; imports require an explicit add action and never send automatically.
- Added read-only confined file trees, change/diff views, persisted transcript FTS search and bounded redacted Markdown/JSON exports with explicit Android sharing.
- Added memory revision conflict detection and history. Authenticated bridge registration supplies the checkpoint revision cache; the model-facing checkpoint tool gains no revision parameter and still requires local acknowledgement.
- Added identity-scoped durable native preferences, drafts, operations and prepared image storage; system picker, permissioned camera/share imports and FileProvider exports retain local trust boundaries and surface storage failures.
- Added component diagnostics, safe idle managed-writer save/close/resume, update blockers and same-computer manifest/checksummed backup with scheduled restore. Restore retains current authorization/revocations and never replays commands or overwrites source terminal journals.
- Removed the package/journal 1 GiB admission limit from authoritative SQLite migration opens. Existing multi-GiB databases are paged by SQLite and retained; bounded backup bundles still enforce their total-byte budget. A large sparse-database regression protects upgrade startup without deleting history.
- Source bootstrap now uses both current and previous runtime patches for conflict-detecting private-runtime upgrades. Already-running terminal closures require a normal fresh launch to activate host exports.

Signed Android and self-contained Linux distribution packages were built; the packaged desktop passed isolated native install/reopen/close/diagnostics acceptance. Source commit `af00084` was pushed and rebuilt; Android 1.1.0 (4) installed on Samsung with the same signer and exact base-APK read-back hash, retaining data and pairing. Its October 20 bounded same-pair Wi-Fi/reconnect, choice/custom and Android inline-notification reply acceptance passed; later offline-follow-up LAN and USB instability remain separately recorded. See `VERIFICATION.md` for version-scoped evidence and limits.

## Unreleased — local Android companion

- Android 1.0.2 (3): preserve project/session row order while the screen is open, instead of promoting rows on every token-driven `updatedAt` change. Content and timestamps remain live; search/filter changes retain existing positions, new rows enter once and removed rows disappear.
- Prepared PC 0.1.1 and Android 1.0.1 (2) with distinct installed-version diagnostics and same-signer Android updates.
- Bounded native UI delivery and disposable cache work; coalesced message revisions, snapshot-first reconnect, revision-fenced history reloads and reply-priority capacity keep historical traffic separate from current decisions. Cache persistence is best-effort; authoritative PC history is retained.
- Accepted answers settle the newest cached/UI state immediately; late pending snapshots and failed background refreshes cannot reopen an answered request or report it as unsent. Duplicate in-flight submissions are rejected without losing drafts.
- External QR/deep-link pairing now requires explicit PC identity/fingerprint and trust-replacement consent before network pairing or cache changes; cancelling preserves the previous computer and cached projects.
- Restored safe resume for valid failed/disconnected/closed saved sessions, preserving managed visible IDs separately from native journal IDs. Canonical roots, source identity and active ownership leases prevent overlapping writers.
- Added authenticated update preparation/cancellation; active native children and outstanding commands block activation. Reopening stages new resources; edited integrations are preserved with warnings. Legacy services without the update handshake are not forcibly restarted.
- Persisted the private LAN port and moved automatic route rebinding inside the same daemon, preserving native children, pending pairing, admin/scanner and TLS identity. Busy saved ports show a recoverable error instead of silently changing endpoints.
- Reduced duplicate journal storage by coalescing superseded complete message revisions without deleting unique history, resets, decisions, notification/runtime events or command outcomes. Persisted minute-resolution authenticated-device last-seen timestamps.
- Kept revocation responsive when a WebSocket writer stalls. Reconciled expired/missing decision notifications, semantic command failures and pairing generations before inline replies.
- Matched host ask semantics: empty multi-selection remains valid, expiry returns recommended answers, bridge notes survive and unsupported native notes are explicitly unavailable. Pending replay cannot mutate original questions, transport or deadlines.
- Hardened phone task flows: offline drafts, dirty checkpoint Back confirmation, missing source sessions, stale file previews, inactive composers, permission retry, keyboard/large-text reflow and accessible input labels.

- Kept the native PC event loop responsive when a Wayland window is hidden on another workspace: presentation no longer waits synchronously for compositor frame callbacks. The existing timed repaint scheduling remains in place; ANR detection is not disabled.
- Made custom `ask` answers explicit radio/checkbox choices. Single-choice offered/custom modes are exclusive, inactive drafts are omitted, blank custom text cannot submit, and context notes stay separate.
- Fixed duplicate pending questions and stale phone answers after terminal session switches/branches: the extension now tears down the old UI/transport before reinitialization, retains one dialog bridge owner, and makes closed retained wrappers inert delegates. Separate identical invocations are not merged.
- Fixed Android heap exhaustion during large real-history replay: WebSocket reads now apply backpressure, transcript events avoid full snapshot disk parsing, and unopened conversations no longer accumulate in Dart memory. Credentials and pairing remain intact during same-signer APK updates.
- Corrected built-in OMP `ask`/tool-dialog responses to use their originating native RPC transport instead of the extension-only dialog bridge. Bundled runtime acknowledgements distinguish accepted and stale responses before stored decisions settle.
- Capability-gated phone resume and clarified terminal-open/read-only sessions with a same-project new-session path. Saved, cleanly closed managed sessions retain resume; current live terminal ownership is never bypassed.
- Made private runtime bootstrap upgrades tolerate an already-applied lifecycle export while independently applying the native-response patch.
- Removed reconnect latency from unbounded historical catch-up: Android loads the current authenticated snapshot before WSS, reloads open conversation pages with generation fencing, and receives decisions without first consuming the old journal. Archive growth now emits only changed/new messages with stable paging positions; true branch changes still reset history. Duplicate raw message-event payloads are no longer journaled beside materialized messages.
- Fixed repeated full-snapshot flooding on an already caught-up WebSocket: one authoritative snapshot is sent per connection, followed by incremental journal events, rather than resending the complete project/session view on every watermark change.
- Reduced Android Gradle defaults to a 1536 MiB heap, one worker, in-process Kotlin compilation and no parallel project execution after the observed workstation-wide terminal-scope OOM incident.
- Replaced command-driven onboarding with a self-contained Linux desktop application: no-argument launch installs its bundled OMP runtime/bridge, user menu and startup integration, selects a private LAN listener, supervises service recovery and reuses one local service. Existing unrelated integration files are preserved.
- Added incremental read-only discovery of configured OMP session/profile roots and automatic project registration. Future normal OMP launches load the installed bridge; pre-existing uninstrumented live sessions remain honestly read-only, without process injection or duplicate resume.
- Added Android nearby-PC DNS-SD/bounded local-broadcast discovery, native PC matching-code approval, same-certificate address rediscovery and automatic reconnect. Terminal/IP/JSON setup is no longer the normal user flow; PC-app QR remains secondary recovery.
- Hardened initial discovery pairing with two-sided v2 commit/reveal, immutable transcript verification, local six-digit code derivation, cancellation fencing and one-use approval. Rediscovery uses an independent bounded probe worker, preventing advertisement floods from occupying interactive API work. Removed the obsolete manual service installer.
- Added a local Rust PC service/CLI, OMP TypeScript bridge and native-backed Flutter Android controller. HTTPS/WSS connects the phone directly to its PC; no hosted relay, cloud database, FCM, analytics or managed VPN is introduced. Existing OMP model-provider configuration remains unchanged; remote models are not made offline.
- Added project-first continuity: separate recent activity and durable, source-linked memory; acknowledged `omputer_checkpoint` persistence; saved-session history/resume; cached offline project data and transcripts.
- Added managed native `rpc-ui` sessions and explicitly registered terminal sessions, transcript updates/history, session/model/thinking controls and OMP subagent lifecycle controls.
- Added contextual select, confirm, input, editor, ask and approval handling, including multi-select and Android inline text replies. Background connectivity uses a visible Android foreground service and local notifications; approvals open their context rather than offering blind lock-screen authorization.
- Added one-use expiring pairing bundles and locally rendered CLI QR codes, exact TLS certificate pinning, hashed PC device credentials, Android Keystore-backed credential encryption and device revocation.
- Added persistent command UUID deduplication, native runtime ownership leases against double resume, validation before interaction claims, first-valid desktop/mobile answer arbitration, authoritative pending replay, transcript branch resets and same-position revision handling.
- Confined project file reads beneath registered roots and kept credentials/provider transport internals out of phone snapshots. A paired phone remains a high-trust controller capable of PC execution.
- Finished and independently reviewed the native phone UI using actual Android emulator captures, including light/dark appearance and enlarged text. This is a phone-screen ship assessment, not physical-device, tablet, landscape, accessibility-service or performance certification.

See `VERIFICATION.md` for exercised evidence and remaining device/network verification limits. Final native authentication/concurrency smoke and the bounded source follow-up completed; physical-device, WAN and accessibility-service validation remain explicitly unclaimed.
