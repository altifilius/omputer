# Automatic startup and discovery contract

User correction: no terminal commands, manual service start, project registration, address typing, or runtime bootstrapping in the normal product flow. Preserve local-only security and existing UI world.

## Deliverable

Linux desktop app (Rust/egui) launched by double-click: self-contained bundle includes `omputer`, patched compiled `omp-runtime`, and `bridge/` files; no Cargo/Bun/git download at user startup. Running `omputer` without a subcommand opens native PC application; explicit CLI subcommands remain diagnostic/developer interfaces, not onboarding. Desktop owns installation, menu/service/autostart, readiness, a stable private LAN port, local approval, devices and truthful staged-versus-running update status. No global compositor/browser manipulation. Closing the window does not stop the daemon.


## Desktop/service local admin

Mode0600 Unix `<stateDir>/admin.sock`; same-user token `<stateDir>/bridge.token`. JSONL one request/response connection `{token,id,action,payload}` -> `{id,success,data?,error?:{code,message}}`. Desktop uses this, never network auth bypass. Actions:
- `status` -> `{serverId,serverName,fingerprint,certificate,port,urls,ready,projects,sessions,pendingPairs,devices,discovery,managedRpcSessions,components,update,backups}`; project/session values are counts. Component identity is distinct from staged package metadata.
- `pair.approve` `{requestId}` -> `{approved:true}`; `pair.deny` `{requestId}` -> `{denied:true}`.
- `pair.bundle` `{}` -> standard one-use bundle with automatically selected LAN URL; desktop can display real QR.
- `device.revoke` `{deviceId}` -> `{revoked:true}`.
- `rescan` -> import/discovery result.
- `update.prepare` -> `{prepared:true,managedRpcSessions:0}` only after acknowledged work drains and all owned native children exit; reserves admission until application or cancellation. `update.cancel` releases reservation. Old daemons without the handshake are not forcibly restarted.
- `update.blockers` reports actual managed/external writer and in-flight work blockers. `update.closeIdle` saves/flushes and closes only settled managed writers; active work, human decisions or external terminal ownership reject rather than force termination. `update.resume` `{sessionId}` uses the normal safe-resume command and lease checks.
- `backup.create` prepares admission, creates a local manifest/checksummed backup, then releases admission. `backup.restore` `{backupId}` validates and schedules restore for normal service startup; success retains the preparation reservation. `backup.cancelRestore` cancels the pending request and releases it. No live database replacement is implied.
- `diagnosis.export` creates a private local diagnostic export. Authenticated HTTPS `/v1/diagnostics` is read-only; backup/restore/admin remain on owner-only IPC.

Backups are same-computer only: server ID and TLS fingerprint must match. TLS keys/certificate and bridge token are never backed up or replaced. Restore retains current device authorization/revocations, removes pairing challenges and never replays commands. Source journals restore to private copies, never overwrite original terminal journals. Manifests/checksums and bounded owned regular-file validation are checked before restore. Diagnostics/components show running daemon/runtime/bridge and staging/update information without exporting provider credentials.
The authoritative SQLite database is opened through same-user regular-file validation without the 1 GiB component/journal cap. Migration creates an online SQLite recovery snapshot before schema changes; it does not truncate history to fit an archive limit. Explicit backup/restore bundles remain bounded to 8 GiB total, with 1 GiB per journal/component and the remaining total budget available to the database.

Stable serverId generated once in private state. TLS fingerprint exact pin identity already exists. Mode0700 dir and mode0600 sockets/tokens. Admin not exposed on HTTP. Each action validates and bounds inputs.
Reopening a newer package stages its byte-verified resources and integrations before activating the existing window. Locally edited/unrelated integrations are preserved and surfaced as warnings; unrelated units are not enabled/restarted. Applying a prepared update targets only the authenticated app-owned service or exact fallback child. Terminal OMP processes load bridge changes on their next normal launch, not through hot module replacement.

The selected port persists in mode-0600 `lan-port`; fresh installations default to 8787, explicit user-service overrides take precedence. Busy-port recovery keeps the saved port. Network route changes rebind only HTTPS/advertisements inside the existing daemon, preserving native ownership, local admin/scanner and pending pairing.


## LAN discovery

mDNS DNS-SD `_omputer._tcp.local.` carries `{id:<stable serverId>,fp:<sha256 hex>,v:1}` plus name/host/port. Do NOT broadcast pairing secret or control credential. TLS always required. DNS-SD is untrusted discovery; it is never alone permission to control.

REST public pairing flow (same HTTPS origin):
- GET `/v1/identity` -> `{version:1,serverId,serverName,certificate,fingerprint}`; only identity metadata, no project/user data/token.
- POST `/v1/pair/request` `{name,clientCommitment}` -> `{version:2,requestId,claimSecret,serverCommitment,expiresAt}`. Both sides commit fresh 256-bit secrets before revealing either secret. No code or PC approval is available at this step.
- POST `/v1/pair/reveal` `{requestId,claimSecret,clientSecret}` -> `{version:2,serverSecret,verificationCode}`. PC validates the original client commitment; Android validates the immutable server commitment and derives the six-digit code locally. Full canonical transcript: `PAIRING-V2.md`. Old `clientNonce` requests are rejected, with no v1 fallback.
- POST `/v1/pair/claim` `{requestId,claimSecret}` -> pending `{status:'pending'}`; denied/expired explicit; approved atomically consumes once -> `{status:'approved',deviceId,token,serverName,serverId}`.
Desktop local approval requires the human to compare the same six-digit code shown on phone. No typing; unrevealed requests cannot be approved. Two-minute original expiry, five active requests, bounded origin/global rate limits. Untrusted discovery never auto-approves or replaces stored credentials. Existing QR trust flow remains secondary recovery in the native PC app; no JSON/commands in primary onboarding.

## Service initialization APIs

`LocalServices` owns local admin, discovery and automatic archive scanning for daemon lifetime. The HTTPS listener may rebind while these services and native runtime ownership remain alive. Public pairing handlers use the shared local pairing queue. Readiness follows listener/service initialization; desktop health/status must not leak model credentials.

## Automatic session/project discovery

Discover current configured OMP storage roots and profiles using existing runtime conventions; import JSONL read-only incrementally by mtime/size. Canonical cwd auto-registers projects. Never resume/duplicate active writer to gain control. No startup model calls. Skip corrupt active/incomplete lines without rewriting source; retry after changes. Surface status (imported/active-unbridged/missing path) honestly. Parent installs a user extension entry automatically for future normal OMP invocations; existing uninstrumented processes cannot be memory-injected or silently restarted.

## Android channel additions

- `discover` `{enabled:true|false}` -> `{scanning,error?}`. Event `{type:'discovery',data:{computers:[{id,name,url,fingerprint}],scanning,error?}}`. NSD only; optional own bounded UDP discovery fallback for emulator compatibility, never probe global networks or ARP/subnet brute force.
- `pairRequest` `{computerId,name,background}` -> `{requestId,verificationCode,expiresAt,serverName,fingerprint}`; native resolves the discovered identity, verifies the advertised certificate, completes strict v2 commit/reveal, verifies the captured server commitment and derives the code locally. Claim secret, both random secrets and commitments never reach Dart/logs. Human code comparison remains required.
- `pairPoll` no args -> `{status:'pending'|'approved'|'denied'|'expired',verificationCode?,...}`. Approved persists credentials atomically, clears previous-PC cache, starts connected foreground policy according OS authorization.
- `pairCancel` -> clears local pending state, does not silently pair.
Auto NSD updates for previously paired serverId may update only URL (never cert/token) with exact existing TLS pin check before use. Network callbacks trigger reconnect; cache remains accessible. Foreground/boot restrictions still truthful; boot receiver allowed to start opted-in connected-device service with required Android permissions. Notifications permission asked in app, no silent grant.

## Verification

Required acceptance covers default native desktop startup with no shell bootstrap, daemon reuse/recovery, UI-close survival, read-only archive import, discovery/pairing single-use authorization, safe update/backup blockers, and Android real native flows. Evidence and remaining limits belong in `VERIFICATION.md`, not in an assumed release claim. Desktop automation uses isolated Xvfb, not the user's compositor. Emulator network constraints must be reported honestly. Physical Samsung acceptance is not claimed here; that device belongs to another session. Source changes do not establish newly packaged or installed artifacts.
