# Changelog

## Unreleased — local Android companion

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
