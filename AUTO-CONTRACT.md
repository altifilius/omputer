# Automatic startup and discovery contract

User correction: no terminal commands, manual service start, project registration, address typing, or runtime bootstrapping in the normal product flow. Preserve local-only security and existing UI world.

## Deliverable

Linux desktop app (Rust/egui) launched by double-click: self-contained bundle includes `omputer`, patched compiled `omp-runtime`, and `bridge/` files; no Cargo/Bun/git download at user startup. Running `omputer` without a subcommand opens native PC application; existing explicit CLI subcommands remain diagnostic/developer interfaces, not onboarding. Desktop app handles single instance, installation to user-owned application directory, desktop-menu entry, enabled user service/autostart fallback, daemon health/readiness, LAN listener address/ephemeral port, current pair approval requests, devices and truthful status. No global compositor/browser manipulation. Closing desktop window does not stop daemon.

## Exclusive implementation boundaries

- Desktop owner: `pc/src/desktop.rs`, `pc/src/setup.rs`, `pc/src/supervisor.rs`; integration `main.rs` optional command/default desktop entry; root packaging owned by parent. May add eframe dependency to pc/Cargo.toml in coordination.
- Service owner: `pc/src/discovery.rs`, `pc/src/local_admin.rs`, `pc/src/autodiscover.rs`, plus `server.rs`, `runtime.rs`, `archive.rs`, `store.rs` as needed; do not edit main.rs or Cargo.toml. Parent coordinates service initialization. No tests/build/lint/format while work runs.
- Android owner: all `mobile/**`, including native Kotlin discovery, Flutter pairing/controller/settings, tests. Keep native-channel model, single-authority credentials and direct connection. No root contract/docs edits.
- Parent: root contracts/docs/assets/scripts, OMP runtime build/core bundle and final integration/verification. Shared initializer APIs below fixed before edits.

## Desktop/service local admin

Mode0600 Unix `<stateDir>/admin.sock`; same-user token `<stateDir>/bridge.token`. JSONL one request/response connection `{token,id,action,payload}` -> `{id,success,data?,error?:{code,message}}`. Desktop uses this, never network auth bypass. Actions:
- `status` -> `{serverId,serverName,port,urls:[https origins],ready,projects,sessions,pendingPairs:[],devices:[],discovery:{...}}` counts allowed.
- `pair.approve` `{requestId}` -> `{approved:true}`; `pair.deny` `{requestId}` -> `{denied:true}`.
- `pair.bundle` `{}` -> standard one-use bundle with automatically selected LAN URL; desktop can display real QR.
- `device.revoke` `{deviceId}` -> `{revoked:true}`.
- `rescan` -> import/discovery result.

Stable serverId generated once in private state. TLS fingerprint exact pin identity already exists. Mode0700 dir and mode0600 sockets/tokens. Admin not exposed on HTTP. Each action validates and bounds inputs.

## LAN discovery

mDNS DNS-SD `_omputer._tcp.local.` carries `{id:<stable serverId>,fp:<sha256 hex>,v:1}` plus name/host/port. Do NOT broadcast pairing secret or control credential. TLS always required. DNS-SD is untrusted discovery; it is never alone permission to control.

REST public pairing flow (same HTTPS origin):
- GET `/v1/identity` -> `{version:1,serverId,serverName,certificate,fingerprint}`; only identity metadata, no project/user data/token.
- POST `/v1/pair/request` `{name,clientCommitment}` -> `{version:2,requestId,claimSecret,serverCommitment,expiresAt}`. Both sides commit fresh 256-bit secrets before revealing either secret. No code or PC approval is available at this step.
- POST `/v1/pair/reveal` `{requestId,claimSecret,clientSecret}` -> `{version:2,serverSecret,verificationCode}`. PC validates the original client commitment; Android validates the immutable server commitment and derives the six-digit code locally. Full canonical transcript: `PAIRING-V2.md`. Old `clientNonce` requests are rejected, with no v1 fallback.
- POST `/v1/pair/claim` `{requestId,claimSecret}` -> pending `{status:'pending'}`; denied/expired explicit; approved atomically consumes once -> `{status:'approved',deviceId,token,serverName,serverId}`.
Desktop local approval requires the human to compare the same six-digit code shown on phone. No typing; unrevealed requests cannot be approved. Two-minute original expiry, five active requests, bounded origin/global rate limits. Untrusted discovery never auto-approves or replaces stored credentials. Existing QR trust flow remains secondary recovery in the native PC app; no JSON/commands in primary onboarding.

## Service initialization APIs

`LocalServices::start(app: Arc<App>, address: SocketAddr, server_name: &str) -> anyhow::Result<LocalServices>` in service module (owner may use `discovery::LocalServices` facade). Holds mDNS, admin socket, auto archive scanner and pair request queue for daemon lifetime. Uses app.store/config, automatic stable identity. Server router public pairing handlers need shared queue accessible via App (owner adds field). `main.rs` owner calls this after TCP bind, before OMPUTER_READY. Desktop admin status health checks do not leak model credentials.

## Automatic session/project discovery

Discover current configured OMP storage roots and profiles using existing runtime conventions; import JSONL read-only incrementally by mtime/size. Canonical cwd auto-registers projects. Never resume/duplicate active writer to gain control. No startup model calls. Skip corrupt active/incomplete lines without rewriting source; retry after changes. Surface status (imported/active-unbridged/missing path) honestly. Parent installs a user extension entry automatically for future normal OMP invocations; existing uninstrumented processes cannot be memory-injected or silently restarted.

## Android channel additions

- `discover` `{enabled:true|false}` -> `{scanning,error?}`. Event `{type:'discovery',data:{computers:[{id,name,url,fingerprint}],scanning,error?}}`. NSD only; optional own bounded UDP discovery fallback for emulator compatibility, never probe global networks or ARP/subnet brute force.
- `pairRequest` `{computerId,name,background}` -> `{requestId,verificationCode,expiresAt,serverName,fingerprint}`; native resolves the discovered identity, verifies the advertised certificate, completes strict v2 commit/reveal, verifies the captured server commitment and derives the code locally. Claim secret, both random secrets and commitments never reach Dart/logs. Human code comparison remains required.
- `pairPoll` no args -> `{status:'pending'|'approved'|'denied'|'expired',verificationCode?,...}`. Approved persists credentials atomically, clears previous-PC cache, starts connected foreground policy according OS authorization.
- `pairCancel` -> clears local pending state, does not silently pair.
Auto NSD updates for previously paired serverId may update only URL (never cert/token) with exact existing TLS pin check before use. Network callbacks trigger reconnect; cache remains accessible. Foreground/boot restrictions still truthful; boot receiver allowed to start opted-in connected-device service with required Android permissions. Notifications permission asked in app, no silent grant.

## Verification

Must prove default native desktop path launches/prepares daemon with no shell bootstrap, repeated open reuses one daemon, crashed daemon restart bounded, service survives UI close, auto archive/project import, LAN discovery and approval/claim token single-use, unapproved request cannot control, Android actual discovery/pairing UI and native screenshots. Native desktop capture uses isolated Xvfb for automated input/screenshot (not user's compositor). Android emulator may need private virtual network for mDNS/UDP; state network limitation rather than test fake production endpoints. Build final release APK and self-contained desktop distribution.
