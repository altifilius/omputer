# Omputer

Monitor OMP sessions on your own PC from an Android phone, answer agent questions, and pick up where you left off in a project.

**No cloud backend, hosted relay, FCM, managed VPN, analytics, or remote UI resources.** The phone connects directly to the PC over HTTPS/WSS. Project memory and the event journal are stored in SQLite on the PC. Device credentials are encrypted using Android Keystore, and previously viewed content is kept in the phone's private cache. Omputer does not change your OMP model provider: a remotely hosted model does not become an offline model by using this application.

The current application interface is in Turkish. This README uses English descriptions and includes the existing interface labels where needed.

Release artifacts: **PC 0.2.0 · Android 1.1.0 (4) · bridge 1.1.0**, built with the private OMP 18.10.2 runtime. `dist/build-info.json` distinguishes packaged, installed and running hashes; `VERIFICATION.md` records exercised workflows and remaining hardware acceptance. A successful build is not a physical-device pass.

## Components

- `pc/`: Rust local service and native PC application, with automatic installation/startup, local discovery, phone approval, TLS, device authorization, and session management.
- `bridge/`: TypeScript OMP extension for structured questions and permissions, subagent control, and source-linked checkpoints. It does not use hosted Collab.
- `mobile/`: Flutter Android application with a Kotlin direct-connection service, notification actions, certificate pinning, and protected local credentials.
- `PROTOCOL.md`, `MOBILE-CONTRACT.md`, `AUTO-CONTRACT.md`, `PAIRING-V2.md`: implemented interfaces and trust boundaries.

## First use — no terminal commands

These steps use the local distribution files. The `dist/` directory is not tracked in Git; source-build instructions are below.

1. On your Linux x64 PC, **open `dist/Omputer`**. If your file manager requires it, enable execution permission in the file's properties. The application extracts its bundled OMP runtime, installs itself for your user account, and starts the phone connection. You do not need to install Cargo, Bun, Android Studio, or terminal tooling to run the packaged application.
2. On your Android phone, **install and open `dist/omputer-android.apk`**. You must approve Android's installation prompt for this source. Both devices must be on the same private Wi-Fi or local network.
3. Select the discovered PC on your phone. **Compare the six-digit code on both screens.** Only if they match, check the comparison box on the PC and select **Approve phone** (`Telefonu onayla`). Reject the request if the codes differ.
4. Projects and saved sessions appear automatically. If desired, grant the notification permission requested by Android and keep background connectivity enabled with its visible notification.

Normal use does not require starting a service manually, entering an IP address, pasting JSON, registering projects, or downloading a runtime. Security approval and Android permission prompts are never bypassed automatically. A paired phone can execute code as your PC user account; approve only your own phone.

Closing the PC window does not stop the background service. Startup is configured for subsequent user logins; desktop autostart is used if the user service manager is unavailable. Opening the application again does not create a second service. Recovery uses bounded retries, with connection status and a manual retry action available in the PC application.

The native PC window uses non-blocking presentation so moving it to another Wayland workspace does not stall compositor responsiveness checks while frame callbacks are paused. Repaint timing remains controlled by the application; hiding or closing the window does not suspend the phone service.

If the network blocks discovery, open **If your phone cannot find the PC** (`Telefon bilgisayarı bulamıyorsa`) in the PC application to generate a one-use QR code. On your phone, select **Alternative: scan the PC's QR code** (`Alternatif: bilgisayardaki QR’ı okut`). The QR code is an access secret valid for ten minutes; do not share it. QR pairing cannot bypass guest-network isolation, a firewall, or a missing network route between devices.

## Installation and data locations

Installation is limited to the current user account. The application and bundled runtime live in `$XDG_DATA_HOME/omputer/app` (by default, `~/.local/share/omputer/app`), private service data in `$XDG_DATA_HOME/omputer`, and the application-menu entry in `$XDG_DATA_HOME/applications/omputer.desktop`. The user service is installed at `$XDG_CONFIG_HOME/systemd/user/omputer.service`; fallback autostart uses `$XDG_CONFIG_HOME/autostart/omputer.desktop`. Only files recorded as owned by this installation are updated. Unrelated or locally modified integration files are preserved.

The PC application selects a private IPv4 LAN interface and an available port. It does not automatically bind to a public Internet address or all interfaces. Without a private network, the service runs on loopback and rebinds when a suitable network becomes available. It does not change router, firewall, or VPN settings. The PC identity and certificate survive restarts; an address change is accepted only after the exact stored certificate has been verified.

## Existing and new OMP sessions

The PC application scans configured OMP storage directories and profiles, imports saved JSONL history read-only without modifying the source, and registers project paths automatically. A user-scoped extension loader connects the bridge for future normal OMP launches. The system `omp` executable is not modified.

**Already running processes without the bridge are not injected into or restarted.** Their history remains visible with an explicit unbridged status; live control is not falsely advertised. Inactive saved sessions can be resumed from the phone, but a second resume is rejected while a live ownership lease exists. Disconnecting the phone does not stop work on the PC.

The phone offers **Resume session** (`Oturumu sürdür`) only when the service advertises safe resume. A terminal session marked **Open in terminal · read-only on phone** (`Terminalde açık · telefonda salt okunur`) can be inspected, not resumed into a second process. Use **New session in this project** (`Bu projede yeni oturum`) for a separate controllable conversation, or continue the original in its terminal. Valid closed, failed and disconnected saved sessions recover safe resume only after checking the canonical project, actual journal identity and inactive writer lease.

Bridge updates take effect in newly launched OMP processes. A process already running the old extension keeps its module closures even if the desktop package is updated; loading conversation state again is not a reliable hot-code update. Save/close that OMP session normally and resume it in a fresh process when activating a bridge lifecycle fix. Do not start a second writer for its still-open history.
### Updates and connection recovery

Open the newer PC package to stage it. **Apply update** (`Güncellemeyi uygula`) activates only after the local service confirms that managed OMP children and outstanding commands have finished; it never force-closes terminal conversations. An older service without the safe-update handshake stays on its running release until a normal service restart. Already-running terminal extensions still require their own normal close/resume to load new bridge code. Locally edited startup/integration files are preserved and reported instead of overwritten.

The automatic listener retains a private saved port (8787 on fresh installs, or an explicit existing override). LAN route changes replace only the HTTPS listener/discovery inside the same daemon; pairing identity, local IPC and owned sessions survive. If the port is occupied or a firewall blocks the phone, the app reports the condition rather than silently selecting a different firewall target. It does not weaken firewall policy automatically.

The Android settings footer shows the actual installed version/build. A same-signer `adb install -r` update preserves pairing and private data; do not uninstall or clear data to update. External pairing links always require explicit PC identity/fingerprint and replacement confirmation before changing that trust.

Offline project data and recently opened pages use a bounded disposable cache, not a second authoritative history store. Reconnect loads a fresh authenticated snapshot and reloads open conversations. A process death can lose the newest debounced cache checkpoint; PC history and committed credentials are unaffected. The PC coalesces superseded full message revisions but retains unique history, decisions and command outcomes; total PC history is not arbitrarily capped.


## Project continuity

The application distinguishes two sources of context:

1. **Recent activity:** the user's goal, the latest final assistant response, and the next task, with the source session and timestamp. An agent turn ending does not mean the project is complete.
2. **Persistent memory:** the goal, summary, next step, and decisions. The `omputer_checkpoint` tool reports success only after local persistence is acknowledged. Memory can also be edited on the phone and linked to a source session. No extra model request or automatic cloud summary is introduced.

From a session, open the command catalog or structured controls to inspect queues, branches, plans, goals, side questions, owned agents/jobs, models, effort and usage. Availability comes from the running runtime: unavailable terminal-only commands remain unavailable. Read views do not invoke a model; effectful actions require explicit confirmation and idle-only actions reject while work is unsettled instead of interrupting silently. Unknown slash names never fall back to prompts or a terminal. TUI-only interactions, provider credential entry and cloud account setup remain outside the phone contract.

Journal entries and owned-child transcripts have explicit next-page controls. Child history uses exact byte cursors, preserves complete UTF-8 records and reports oversized individual records rather than skipping them. Reading another session's or sibling's child history is rejected.

Use project file browsing, changes/diff and transcript search for read-only inspection. Export creates a bounded, redacted text copy for the Android share chooser; review it before sharing because conversation text can contain secrets. Memory edits detect revision conflicts and preserve revision history rather than overwriting a newer checkpoint.

Composers keep identity-scoped local drafts and prepared image bytes across process restarts. Pick an image, take an explicitly permissioned photo or receive a system share, then choose when to send; imports do not submit automatically. Shared-image notices preserve the reading route and typed text; select **Paylaşılan görselleri ekle** in the intended conversation to add them explicitly. Limits are eight images / 2 MiB aggregate and 1 MiB per image. Storage failures are visible, not reported as a saved draft. Durable UUID operation records distinguish accepted/running, final and unknown outcomes; consult the operation result rather than blindly resending an uncertain action.

In PC settings, inspect running/staged component diagnostics and update blockers. Save/close idle managed sessions explicitly before applying an update; external terminal writers must be closed normally by their owner. Local backups and scheduled same-computer restore preserve the current PC identity and device revocations, never replay commands and never overwrite original terminal journals. They are not a cloud backup or a way to migrate credentials.

## Notifications and connection limits

Enable **Notification permission** (`Bildirim izni`) and **Background connection** (`Arka plan bağlantısı`) in the Android application. A connected-device foreground service maintains the direct WSS connection with a persistent visible notification. Short text/editor responses can be sent from Android notifications; multi-select questions and permissions open in the application with their context. Permission notifications do not offer blind lock-screen approval.

Doze may restrict network and CPU access. Review Android's battery-optimization settings from the application; continuous real-time access has a battery cost. Delivery is not guaranteed after force-stop, without network access, or while the PC is off or asleep. When connectivity returns, events and current state are refreshed; stale answers are not executed again.

Access outside your local network requires your own WireGuard/router VPN or another securely reachable route. Omputer does not configure router ports, firewalls, or VPNs. An unreachable PC behind CGNAT cannot be reached without another reachable endpoint or a relay; no hosted relay is provided. Prefer your own VPN rather than exposing the service directly to the public Internet.

## Building the Android application

Build requirements: Flutter stable, JDK 17, Android SDK 36, and NDK 28.2.13676358. On the development workstation, isolated tools are stored under `~/.local/share/omputer-tools/`; project and system runtimes are not replaced.

```sh
sh scripts/build-android.sh
# Alternatively, with a standard Flutter installation:
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Debug APK: `mobile/build/app/outputs/flutter-apk/app-debug.apk`.
Optimized APK: `mobile/build/app/outputs/flutter-apk/app-release.apk`.

Local distribution files are `dist/omputer-android.apk` (arm64 + x86_64, optimized and signed with the local release key) and `dist/Omputer` (Linux x64 native application with the runtime and bridge embedded). Checksums are stored in `dist/SHA256SUMS`. These generated files are not included in the source repository.

A separate local release-signing identity was created on the development workstation at `~/.local/share/omputer-signing/android-release.p12`. Its directory has mode 0700; key/password files and the ignored `mobile/android/key.properties` have mode 0600. The key is not uploaded to another service. Back up the signing identity securely: if it is lost, updates cannot be installed over the existing application using the same identity. Debug and release signatures differ; switching from a debug installation requires uninstalling it and pairing again.

To build a release on another machine, configure `storeFile`, `storePassword`, `keyAlias`, and `keyPassword` in `mobile/android/key.properties`, then run `sh scripts/build-android.sh --release`. A debug key is not silently substituted for a release key.

## Developer builds and diagnostics

This section is for building from source, not end-user setup. Building requires Linux, Rust/Cargo, Bun compatible with `bridge/package.json`, and the OMP 18.10.2 sources:

```sh
sh scripts/package-desktop.sh
sh scripts/build-android.sh --release --target-platform android-arm64,android-x64
```

The desktop packaging script creates the embedded OMP runtime and bridge archive and writes `dist/Omputer`. A plain Cargo build without embedded resources is for development only. Explicit CLI subcommands listed by `omputer --help` are optional diagnostics; launching without a subcommand opens the native application. Use `OMPUTER_STATE_DIR` or `--state-dir` for isolated test data. The old manual service-installation script has been removed; the application owns installation and startup.

The source bootstrap is `sh bridge/bootstrap.sh` against pinned OMP v18.10.2 commit `c8913466dd7bf92040de911f8e00e30b8f4e48a2` (override its private source directory with `OMPUTER_OMP_SOURCE`). Keep **both** `bridge/runtime.patch` and `bridge/runtime.previous.patch` alongside it: bootstrap stages pristine/previous/desired trees and merges the upgrade before changing live source files, rejecting conflicts instead of overwriting private edits. It requires the matching native addon and frozen Bun dependencies; packaging embeds the resulting private runtime. New host exports are not loaded into already-running terminal module closures: save/close normally and start/resume a fresh process; do not open another writer on the same live journal.

On a workstation running OMP and an Android emulator, build serially rather than starting Rust, Android and runtime compilation together. The October 17 investigation observed `systemd-oomd` terminate the terminal's entire process scope under combined RAM/swap pressure. Recovery builds used separate user services with `CARGO_BUILD_JOBS=1`, explicit memory/swap ceilings and low CPU priority. Finish Android before Rust packaging, and do not retain its Gradle daemon: this project disables the persistent daemon, parallel workers and the separate Kotlin compiler JVM. Do not disable system OOM protection or treat an emulator passing as physical-phone proof.

## Security and verification

Discovery is not authorization. Initial pairing requires two-sided v2 commit/reveal and human comparison of the codes; the alternative QR flow carries a one-use access secret. Subsequent connections pin the exact TLS certificate. Arbitrary self-signed certificates are not accepted, and identities are never silently rotated. Only device-token hashes are stored on the PC; revocation closes the device's stream. Linux `openat2 RESOLVE_BENEATH` confines file reads to registered project roots. Interaction IDs, deadlines, and first-valid-response arbitration handle competing desktop/phone answers. API keys and provider transport details are excluded from snapshots; conversation content is sent to the paired phone.

See [VERIFICATION.md](VERIFICATION.md) for exercised checks and their limits. Emulator results do not establish physical-device battery or Doze behavior.
