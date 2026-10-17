# Verification record

## Scope and interpretation

This record covers the local PC service, actual OMP runtime integration, an installed debug Android APK and the optimized locally signed release APK on an Android 35 x86_64 Pixel 7 emulator. Entries record observed checks; they do not certify every feature on every physical device.

Final native authentication/concurrency smoke completed on the installed Android emulator: self-revocation with a pending question removed notifications and the foreground service without reposting; re-pair restored access; a prompt submitted through the real composer delivered its live decision while the HTTP command remained independent. The final limited source review reports no remaining findings for atomic pairing/cache cutover, event fencing and critical reply capacity.

| Area | Exercised evidence | Result / boundary |
| --- | --- | --- |
| Rust formatting and lint | `cargo fmt`; Clippy with `-D warnings`, after fixes | Clean in the recorded run; not a new run for this document. |
| Rust tests | `cargo test --workspace` | 40 passed, including automatic profile/session discovery, native installation boundaries, strict pairing v2, one-use claims and prior runtime/continuity invariants. |
| Flutter static analysis | `flutter analyze` | Clean in the recorded run. |
| Flutter tests | `flutter test` | 17 passed, including nearby selection, denial/cancellation fencing and prior transcript/decision regressions. |
| Native Kotlin tests | `:app:testDebugUnitTest`, isolated non-incremental run after concurrent-build cache corruption | 7 passed: shared v2 vector, commitment/field/code mismatch rejection, canonical encoding and exact certificate identity. |
| Android artifact | Debug and optimized release APK built; APK v2 signature verified; release installed and onboarding rendered | Android 35 x86_64 Pixel 7 emulator. Release includes arm64-v8a and x86_64; physical arm64 installation not exercised. |
| Managed OMP session | Actual managed `rpc-ui` native v2 handshake and model listing | Passed against the real runtime, not a simulated production transport. |
| Structured decisions | Actual select, confirm, input, editor and ask flows; Android multi-select UI | Exercised successfully. |
| Permission decision | Fixture invoked actual `ctx.ui.select` and preserved the canonical approval gate | Selector path exercised; no actual destructive command was executed to manufacture approval evidence. |
| Interaction validation and races | Malformed ask rejected before claim, then valid answer accepted; actual desktop TUI answered approval, then stale phone answer rejected | Observed validation-before-claim and first-answer arbitration. |
| Project checkpoint | Registered `omputer_checkpoint` tool invoked directly; PC source memory acknowledgement observed | Real tool/persistence path, without a model request. Not evidence that a model autonomously chose the tool. |
| Resume ownership | Real inactive saved session resumed; second resume of active session rejected | Passed against actual runtime ownership. |
| Session controls | Rename, model and thinking commands | Acknowledgements observed; model selection did not exercise a remote inference request. |
| Command deduplication | Repeated shell command UUID using `printf` | Command ran once. |
| Subagent lifecycle | Real SDK child park → revive → chat using a local slash command → kill | Actual lifecycle exercised without a model call; not evidence of model-generated subagent work. |
| Android pairing | Direct Android pairing with local PC | Passed. CLI pairing QR was also generated locally; camera scanning was not exercised. |
| Background connection | Native foreground service and a background question | Exercised on the emulator. No physical-device/Doze reliability guarantee follows. |
| Notification response | Android inline notification reply | Reply saved in the actual OMP transcript. |
| Background setting | Disabled background connectivity while app remained foreground | Foreground use retained. |
| Offline continuity | Cold app access with `adb reverse` removed | Cached offline state exercised, not an available live connection. |
| Native visual review | Actual phone screenshots: dark/light, font scale 1.3, Back navigation, project detail and decisions | Independent NativeFinishReviewer disposition: ship; seven actual 1080×2400 captures reviewed. No material visual blocker established. |
| Runtime errors | Native `AndroidRuntime` and Flutter error logs during the exercised native flow | Empty in the observed run; not a blanket claim about all future execution. |
| Local transport boundary | PC ↔ Android and local OMP bridge | No cloud transport introduced. User provider configuration unchanged; remote models remain remote. |

## Automatic startup and pairing verification

The final self-contained `dist/Omputer` was opened without arguments in a private HOME/XDG installation, private network namespace and owned Xvfb display. It extracted its bundled OMP runtime, installed the user menu/service/autostart and future-terminal bridge loader, started its service, and imported one stored JSONL session/project without bootstrap commands or project registration. Fixtures were test-only, not shipped data. A second no-argument open returned successfully with unchanged supervisor/daemon PIDs. Normal `WM_DELETE_WINDOW` closure exited 0 while the service remained ready. Terminating only the owned test daemon caused automatic restart with the same server identity and a new port.

The final signed release APK was installed on Android 35 x86_64 and discovered the actual PC over the isolated LAN without an injected URL or `adb reverse`. Both native screens displayed the same v2-derived code. Android notification permission was explicitly accepted, the PC comparison checkbox/approval was exercised, and real imported project content appeared on the phone. Before approval, an unauthenticated snapshot returned HTTP 401. Cancelling a pending request kept the phone unpaired even when that old request was subsequently approved on the PC; no device token was issued by that approval alone. A fresh request then paired successfully.

An actual private-LAN address change forced the automatic PC service to rebind on a new port. The signed Android app rediscovered it, retained the same paired server identity/certificate and showed connected at the new URL without re-pairing or manual reconnect. Rebinding and throttled discovery are asynchronous; this proves eventual recovery, not instant transition or delivery latency.

A bounded burst of 120 untrusted discovery replies targeting unreachable alternate ports was sent only to the owned Android discovery socket on the private LAN. The signed app retained actual project content during a refresh, the PC stayed ready, and the unverified ports did not replace the paired address. This is a bounded responsiveness/identity smoke, not an exhaustive denial-of-service benchmark.

The final bounded security source review closed both prior findings: offline SAS grinding and discovery-probe starvation of interactive requests. This is not an independent penetration-test certification. The final APK signature verifies as APK v2 with the original local release signer; application/Flutter engine code is included for arm64-v8a and x86_64.

Verification used only owned namespaces, emulator, installation roots and Xvfb. It did not modify the user's compositor, real network, router, firewall or user service manager. The fallback supervisor was exercised; the generated systemd unit was inspected, not enabled in the real user manager. Earlier forced X11 window destruction triggered a winit `BadWindow` panic; the normal close protocol in the final smoke exited cleanly. A transient emulator System UI ANR was dismissed before the signed app flow; it is not counted as an Omputer app crash or physical-device performance evidence.

## Native design assessment

The independent finish review used actual emulator captures and sampled Flutter sources against `PRODUCT.md` and `.impeccable/surface-briefs/android.md`. It accepted the native phone hierarchy, contextual decisions, safe insets, enlarged-text reflow, source-linked memory, native notifications and explicit offline state. Disposition: **ship**, at phone UI scope. Final native request/authentication fixes did not change the reviewed layout.

This is a **phone-only screenshot assessment**. There was no approved image composition to match, no shipping photography and no applicable web-detector check. Android icons use native vectors and generated Flutter defaults, not generated imagery. Tablet/landscape, physical performance, independent TalkBack and independent motion verification are not covered.

## Fixture provenance and cleanup

Smoke extensions were throwaway integration drivers for real runtime APIs, not production features, fake user work or seeded production sessions. They exercised dialogs, explicit checkpoint calls and local slash-command/subagent paths without requesting model inference. The owned OMP processes were closed and temporary extensions, workspace and SQLite test state removed after the final smoke gate. They are not part of the permanent installation or seeded project history.

Temporary test bearer credentials, emulator reverse mappings and smoke listener ports are deliberately not documented as permanent setup. Follow `README.md` for real pairing, state-directory and network setup.

## Explicitly untested or excluded

- Physical Android hardware and its camera-based QR scan.
- Real off-LAN/WAN access through the owner's WireGuard/router VPN, NAT/firewall conditions or CGNAT traversal. No hosted fallback exists.
- Physical-device Doze, OEM battery management, force-stop recovery, long-running notification delivery, battery consumption or performance guarantees.
- TalkBack service operation, tablet/landscape layouts and independent reduced-motion behavior.
- Actual destructive approval execution, model inference during the checkpoint/subagent/control smoke, or conversion of remote provider models into offline models.
- Physical-device release installation and store/distribution-platform validation. Local APK v2 signature, emulator installation and actual optimized onboarding launch were verified.

An existing terminal-launch MCP Figma authorization failure (`401`) was unrelated to the local app transport and is not counted as an Omputer check failure or a successful Figma connection.
