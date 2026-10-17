# Omputer implementation plan

## Outcome

An Android companion and a self-contained Linux desktop application supervising its local service. Open the PC app, select the automatically discovered PC on Android, compare codes and approve locally; normal startup requires no terminal/IP/JSON/project-registration steps. No hosted service, managed VPN, FCM, analytics, CDN, or cloud database. The PC is the authoritative executor; the phone is a securely paired controller. Existing OMP model-provider configuration is unchanged: Omputer adds no model/cloud dependency, but does not turn a remote OMP model into an offline model.

## Components

- `pc/`: Rust native desktop application, automatic user-owned installation/startup and bundled OMP runtime, supervised daemon and optional diagnostic CLI. Axum HTTPS/WSS, stable local TLS identity, SQLite journal, device/pairing management, automatic project/session discovery, project memory and authenticated Unix-domain sockets.
- `bridge/`: OMP TypeScript extension. Registers actual terminal sessions, exports events/state, handles structured commands and races local/mobile dialogs. The PC app installs a user-scoped extension loader for future normal OMP launches; existing uninstrumented processes are not injected, duplicated or silently restarted. Uses local IPC, not hosted Collab.
- `mobile/`: Flutter Android application, project-first Material 3 screens, persistent offline snapshot, source-linked project checkpoints, live transcripts, interaction inbox, model/subagent/session controls.
- `mobile/android/`: small native Kotlin service owns background WSS and Android notifications, encrypted credential storage, inline replies, action intents, connection status, battery settings. Foreground UI does not create a second controller socket.

## Security and networking

1. On first service start generate a TLS identity and random local-bridge credential in a mode-0700 state directory.
2. Untrusted local DNS-SD/bounded UDP discovery locates the PC. Strict v2 two-sided commitment/reveal binds random secrets and the certificate, then both native surfaces show a locally derived six-digit code. Only matching-code human approval on the PC permits token issuance. PC-app one-use ten-minute QR is secondary recovery; exact certificate pinning remains mandatory. Details: `PAIRING-V2.md`.
3. Successful pairing returns a random device bearer token; only its SHA-256 hash is stored in SQLite. Android stores it encrypted using Android Keystore. Revocation closes/rejects access.
4. HTTPS request and WSS upgrade both require the token. Secrets are not placed in URLs or logs. A paired controller can cause PC execution and is a high-trust device.
5. Outside-home access needs the owner's reachable IP/port or own WireGuard/router VPN. No auto port-forwarding, router changes, or third-party relay. CGNAT and a sleeping PC are genuine reachability limits.
6. Only locally registered project roots can be launched. Saved sessions are resumed only under their recorded root and never opened a second time while live.

## Event and interaction invariants

- Monotonic journal sequence; reconnect replays after the persisted cursor and refreshes the authoritative snapshot.
- Transcript pages and incremental events are separate; text updates replace by message ID, not append duplicate deltas.
- Commands carry UUID IDs. Outcomes are acknowledged; a lost acknowledgement never silently repeats a destructive operation.
- Pending interactions have stable request IDs, session ID, method, title/body/options/questions, deadline, and status. First valid desktop/mobile answer wins. Expired/cancelled/resolved answers are rejected.
- Disconnecting the phone does not interrupt OMP. Bridge loss temporarily retires non-actionable inbox entries; authoritative host-pending replay restores stable request IDs and reconciles unconsumed answer claims. A disconnect never manufactures a host answer.
- Agent turn ended, settled with no async work, explicit task completion, and project completion are not conflated.

## UI direction

Native Android navigation and controls; an ink-blue/periwinkle visual world with porcelain text, citrus decision emphasis, excellent light mode, generous readable conversation layout, and one timeline-to-session transition. Project continuity and pending human decisions lead. No terminal cosplay, decoration charts, fake data, nested cards, remote fonts, or redundant dashboards.

## Acceptance

- Open the bundled PC app without arguments; prepare/start its service, automatically import saved sessions/projects, preserve identity, reuse one daemon on repeat open, survive UI close and recover after daemon/network changes. Android finds the actual PC, compares codes, pairs after local approval, reconnects and honors revocation; QR is secondary recovery.
- Register a real terminal OMP session and start a new real `rpc-ui` session.
- Read live/history transcript, send prompt/steer/follow-up, abort, choose model, inspect todos/subagents, and resume an inactive session.
- Answer select/confirm/input/editor/ask/approval from phone; desktop answer cancels phone request; stale second answer rejected.
- Maintain/edit project checkpoint and show source plus freshness. Browse cached project data offline.
- Receive locally generated Android notifications while background connection is enabled, navigate to exact request, and reply. Expose permission/battery/connection health honestly.
- Run actual service/RPC smoke; build APK; exercise on local Android emulator or device, inspect phone screenshots, dark/light, Back, keyboard and font scale. No claim of physical-device delivery without a physical device.
