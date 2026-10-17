# Omputer

<!-- impeccable:product-schema 1 -->

## Platform

android

## Stack

Delegated by the user. Flutter/Dart Android application, Kotlin native network/background layer, Rust/SQLite local service and native egui PC application, TypeScript OMP bridge. PC runtime and bridge are bundled. No cloud backend, hosted relay, analytics, remote fonts, or push provider.

## Users

The owner of this Linux PC uses an Android phone to monitor and fully interact with local OMP sessions, including while away from the PC.

## Product Purpose

Make project continuity and agent control available on the phone: see where each project stands, receive and answer questions/selections/permissions, inspect live work, steer running sessions, and start or resume work.

## Operating Context

OMP v18.10.2 is installed. The PC app starts and supervises its service automatically, installs the user-scoped bridge for future OMP invocations, and discovers stored projects/sessions. Android discovers the PC on the LAN and pairs through matching-code PC approval. Normal use requires no terminal commands, manual IP/JSON entry, runtime bootstrap or project registration. Existing running uninstrumented sessions remain read-only until a genuine bridge is loaded; they are not silently restarted. The PC remains execution/data authority; phone disconnect does not stop work.

## Capabilities and Constraints

- Project-first navigation with goals, decisions, open work, next steps, source sessions, and freshness.
- Unified inbox for pending questions, selections, confirmations, and tool permissions.
- Live transcript, tool output, todos, subagents, prompt/steer/follow-up/interrupt, model selection, new sessions, and resume.
- All application data, pairing, notifications, and history stay on the PC and phone.
- Outside-home access uses a user-owned reachable network route, such as WireGuard on the user's router/PC. No managed VPN control plane or hosted relay is permitted. CGNAT cannot be traversed without another reachable user-owned endpoint.
- Android direct-background delivery requires an opt-in connected-device foreground service and possibly battery-optimization exemption. No claim of delivery after force-stop, loss of network, or a sleeping PC.
- Missing OMP host interaction APIs may be added to the bridge/runtime. Do not substitute terminal keystroke injection for structured interaction.
- Secure device pairing, encrypted transport, revoked-device enforcement, stale-question rejection, and safe simultaneous desktop/phone answers.

## Product Principles

1. Project continuity before session bookkeeping.
2. Pending human decisions are always visible and actionable with context.
3. Truthful state: disconnected, stale, waiting, idle, failed, and complete are distinct.
4. Direct local ownership with no hidden external services.
5. Powerful controls without a cramped terminal UI.

## Accessibility & Inclusion

Turkish-first interface. Material 3 navigation and Android Back conventions; 48 dp targets; font scaling, dark/light schemes, accessible semantics, and reduced-motion behavior.
