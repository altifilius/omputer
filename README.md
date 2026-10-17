# Omputer

Monitor OMP sessions on your own PC from an Android phone, answer agent questions, and pick up where you left off in a project.

**No cloud backend, hosted relay, FCM, managed VPN, analytics, or remote UI resources.** The phone connects directly to the PC over HTTPS/WSS. Project memory and the event journal are stored in SQLite on the PC. Device credentials are encrypted using Android Keystore, and previously viewed content is kept in the phone's private cache. Omputer does not change your OMP model provider: a remotely hosted model does not become an offline model by using this application.

The current application interface is in Turkish. This README uses English descriptions and includes the existing interface labels where needed.

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

If the network blocks discovery, open **If your phone cannot find the PC** (`Telefon bilgisayarı bulamıyorsa`) in the PC application to generate a one-use QR code. On your phone, select **Alternative: scan the PC's QR code** (`Alternatif: bilgisayardaki QR’ı okut`). The QR code is an access secret valid for ten minutes; do not share it. QR pairing cannot bypass guest-network isolation, a firewall, or a missing network route between devices.

## Installation and data locations

Installation is limited to the current user account. The application and bundled runtime live in `$XDG_DATA_HOME/omputer/app` (by default, `~/.local/share/omputer/app`), private service data in `$XDG_DATA_HOME/omputer`, and the application-menu entry in `$XDG_DATA_HOME/applications/omputer.desktop`. The user service is installed at `$XDG_CONFIG_HOME/systemd/user/omputer.service`; fallback autostart uses `$XDG_CONFIG_HOME/autostart/omputer.desktop`. Only files recorded as owned by this installation are updated. Unrelated or locally modified integration files are preserved.

The PC application selects a private IPv4 LAN interface and an available port. It does not automatically bind to a public Internet address or all interfaces. Without a private network, the service runs on loopback and rebinds when a suitable network becomes available. It does not change router, firewall, or VPN settings. The PC identity and certificate survive restarts; an address change is accepted only after the exact stored certificate has been verified.

## Existing and new OMP sessions

The PC application scans configured OMP storage directories and profiles, imports saved JSONL history read-only without modifying the source, and registers project paths automatically. A user-scoped extension loader connects the bridge for future normal OMP launches. The system `omp` executable is not modified.

**Already running processes without the bridge are not injected into or restarted.** Their history remains visible with an explicit unbridged status; live control is not falsely advertised. Inactive saved sessions can be resumed from the phone, but a second resume is rejected while a live ownership lease exists. Disconnecting the phone does not stop work on the PC.

## Project continuity

The application distinguishes two sources of context:

1. **Recent activity:** the user's goal, the latest final assistant response, and the next task, with the source session and timestamp. An agent turn ending does not mean the project is complete.
2. **Persistent memory:** the goal, summary, next step, and decisions. The `omputer_checkpoint` tool reports success only after local persistence is acknowledged. Memory can also be edited on the phone and linked to a source session. No extra model request or automatic cloud summary is introduced.

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

## Security and verification

Discovery is not authorization. Initial pairing requires two-sided v2 commit/reveal and human comparison of the codes; the alternative QR flow carries a one-use access secret. Subsequent connections pin the exact TLS certificate. Arbitrary self-signed certificates are not accepted, and identities are never silently rotated. Only device-token hashes are stored on the PC; revocation closes the device's stream. Linux `openat2 RESOLVE_BENEATH` confines file reads to registered project roots. Interaction IDs, deadlines, and first-valid-response arbitration handle competing desktop/phone answers. API keys and provider transport details are excluded from snapshots; conversation content is sent to the paired phone.

See [VERIFICATION.md](VERIFICATION.md) for exercised checks and their limits. Emulator results do not establish physical-device battery or Doze behavior.
