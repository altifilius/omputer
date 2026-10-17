---
name: Omputer Android
description: A local-first Material 3 companion for project continuity and human decisions.
colors:
  ink: "#151d37"
  periwinkle: "#b8b9ff"
  citrus: "#e0ed8b"
  scheme-seed: "#595bc4"
  dark-surface: "#10172a"
  dark-on-surface: "#eeeff8"
  dark-secondary-container: "#353e28"
  light-primary: "#494bb0"
  light-on-primary: "#ffffff"
  light-surface: "#f8f8ff"
  light-secondary-container: "#e7efbc"
  light-on-secondary-container: "#313b0e"
typography:
  wayfinding:
    fontFamily: Roboto
    fontWeight: 600
    letterSpacing: "-0.7sp"
  project-title:
    fontFamily: Roboto
    fontWeight: 600
  reading:
    fontFamily: Roboto
    lineHeight: 1.5
  editor:
    fontFamily: monospace
    lineHeight: 1.5
rounded:
  field-notice: "16dp"
  decision-strip: "20dp"
  activity: "24dp"
spacing:
  compact: "8dp"
  related: "12dp"
  control: "16dp"
  container: "20dp"
  page: "24dp"
components:
  button-filled-dark:
    backgroundColor: "{colors.periwinkle}"
    textColor: "{colors.ink}"
    height: "52dp minimum"
  button-filled-light:
    backgroundColor: "{colors.light-primary}"
    textColor: "{colors.light-on-primary}"
    height: "52dp minimum"
  input:
    rounded: "{rounded.field-notice}"
    padding: "16dp 16dp"
  decision-strip-dark:
    backgroundColor: "{colors.dark-secondary-container}"
    rounded: "{rounded.decision-strip}"
    padding: "20dp"
  decision-strip-light:
    backgroundColor: "{colors.light-secondary-container}"
    rounded: "{rounded.decision-strip}"
    padding: "20dp"
  activity:
    rounded: "{rounded.activity}"
    padding: "20dp"
---

# Design System: Omputer Android

## Overview

**Creative North Star: "Dusk atelier"**

A calm working companion, not a terminal compressed onto a phone. Deep blue surfaces, periwinkle actions, generous headings, and grounded rows make project context readable before exposing session mechanics. Cool paper and indigo give the light scheme its own identity.

Material 3 supplies the interaction vocabulary. Turkish-first copy names the project, the pending decision, the source, and the freshness of a record. Recorded project memory and live conversation context remain visibly distinct; a finished agent turn is not presented as a finished project.

**Key Characteristics:**
- Native Material 3 controls and adaptive navigation.
- Flat grouped rows with selective tonal containers.
- Source-linked context and explicit connection state.
- Readable, system-scaled typography without remote fonts.

This record describes the implemented Flutter Android app, not a web implementation. Dimensions are logical dp and text scales with Android font settings in sp terms. Sources: `mobile/lib/ui.dart`, `main.dart`, `projects.dart`, and `interactions.dart`. Visual evidence: `.impeccable/review/phone-dark.png`, `phone-project-detail.png`, `phone-question.png`, and `phone-large-font.png`. The independent native finish record reports a ship disposition for Android 35 Pixel 7 emulator captures; these captures do not establish tablet, landscape, physical-device performance, TalkBack, or reduced-motion runtime verification.

## Colors

### Primary

Periwinkle is dark-theme `primary`, with ink as `onPrimary`. Light-theme primary is indigo (`light-primary`), with white on-primary. Actions, source links, leading icons, and memory labels use semantic scheme roles, not fixed dark-theme swatches.

### Secondary

Citrus is dark `onSecondaryContainer`; the dark secondary container is muted olive. The light scheme uses pale citrus container and dark olive foreground. Selected Material chips and the waiting-decision strip draw attention through secondary-container tone; citrus is not reserved exclusively for warnings. The strip itself inherits text styling rather than explicitly overriding it with `onSecondaryContainer`.

### Neutral

Dark surfaces are blue-black, with porcelain on-surface text. Light surfaces are cool paper, with ink on-surface text. App bars and compact navigation use the scheme surface. Input fill uses `surfaceContainerHighest` at 0.55 alpha; dividers use `outlineVariant` at 0.65 alpha.

**The Semantic Pair Rule.** Resolve light/dark roles through `Theme.of(context).colorScheme`; do not transplant a dark foreground or background into the light theme.

The frontmatter records exact authored constants and overrides only. Remaining roles—including primary containers, outlines, error colors, and tonal surfaces—come from `ColorScheme.fromSeed` for each brightness. There is no authored tonal ramp or wallpaper-derived Dynamic Color implementation to document.

## Typography

Android Material 2021 typography (`Typography.material2021(platform: TargetPlatform.android)`) is the native hierarchy; Roboto is the Android text face. There is no bundled brand font or remote font dependency. Preserve the SDK role definitions rather than introducing a parallel hand-sized type scale.

- **Wayfinding:** `headlineLarge`, with weight 600 and tightened tracking from the frontmatter, for “Kaldığın yerden.”
- **Screen/empty-state headings:** `headlineSmall`; section headings use `titleLarge`.
- **Project titles:** `titleLarge`, weight 600; activity goals use `titleMedium`.
- **Reading:** `bodyLarge`; extended memory and activity excerpts use the frontmatter reading line-height. Overview excerpts may be line-limited; detail memory remains selectable and reflows.
- **Metadata:** `labelLarge` / `labelMedium` for connection, status, provenance, and timestamps; paths use `bodySmall`.
- **Editor content:** system `monospace`, with the recorded reading line-height. Ordinary answers retain native body typography.

**The Scale-With-The-Reader Rule.** Keep system text scaling and wrapping. Do not replace Material roles with fixed raster text or shrink content to preserve a screenshot composition.

## Layout

The compact home uses three bottom destinations: Projeler, Gelen kutusu, Ayarlar. At available width **720dp and above**, the same destinations become a labeled `NavigationRail` beside the content and a vertical divider. This is a width check, not a device-model check; it is not a claim of a fully verified tablet split-view layout.

Common page gutters are 24dp. Related content uses the frontmatter spacing steps; sections establish a stronger gap (section-heading padding: left 24dp, top 28dp, right 16dp, bottom 12dp). Project rows use left/right 24dp, top 22dp, bottom 24dp. List rows and fine separators carry hierarchy instead of an equal-sized dashboard-card grid.

Home reserves 100dp bottom scroll padding near its extended new-session FAB; project detail reserves 110dp. `SafeArea(top: false)` protects body insets beneath app bars; forms use scrollable content. Filters wrap rather than forcing a single horizontal line. Empty, missing, loading, disconnected, and failed states remain explicit instead of being filled with demonstration data.

## Elevation & Depth

Depth is primarily tonal. Project overview rows are flat; activity context uses `primaryContainer`, and waiting decisions use `secondaryContainer`. The app bar specifies scrolled-under elevation 1. FABs, dialogs, state layers, and navigation indicators retain Material behavior; there are no authored bespoke shadow tokens. Do not substitute glow, glass, or decorative gradients for this hierarchy.

Custom screen navigation fades with a small horizontal translation: 220ms forward, 180ms reverse, `Cubic(.16, 1, .3, 1)`. The translation begins at 0.025 of the child width, or 0.045 for checkpoint routes. `MediaQuery.disableAnimationsOf(context)` makes these custom route durations zero and returns the child without fade/slide. Retain native Material component behavior; this record does not claim every SDK animation has been independently exercised with Remove animations.

## Shapes

Use gently rounded filled fields and notices, softer waiting-decision strips, and larger activity context containers with the frontmatter radii. Fields have no resting outline stroke. Buttons, filter chips, FABs, radio controls, checkboxes, dialogs, and navigation indicators use their Material 3 shapes; do not invent a separate radius scale for those SDK defaults. Fine dividers and crisp Material icons balance the rounded containers.

## Components

### Buttons

Filled buttons are the clear affirmative action. Filled and outlined buttons have a 48dp minimum width and 52dp minimum height; text buttons have a 48×48dp minimum. Tonal buttons resume the recent conversation; outlined buttons expose source records or a negative alternative. Keep Material pressed, focus, disabled, and ink-response states, not web hover effects. A single extended FAB starts a new session on populated project home and is disabled when disconnected.

### Inputs and filters

Filled text fields use the recorded radius and padding with scheme-derived tonal fill. Search exposes a clear action when populated. Native filter chips carry selection state and wrap on narrow screens. Questions use native radio or checkbox list tiles, not custom pseudo-controls; custom answers and contextual notes use multiline fields.

### Project rows and activity containers

Overview rows show project name, goal, next step, session/freshness metadata, and a forward affordance. Detail distinguishes “Son kaldığın yer” (conversation/task-derived activity, when available) from “Projenin hafızası” (persistent goal, summary, next step, decisions). The memory footer identifies agent-sourced versus manually edited records and includes freshness. A source-session button appears when a source exists; it opens the actual session, with a checkpoint-thread marker rather than a decorative identity badge.

### Decisions and first-response states

The waiting-decision strip leads to the inbox. Rows identify project, title, status, and creation time; detail retains the source-conversation action and any deadline. A response is enabled only while the request is pending, connected, and not submitting; structured questions also require valid answers and selection requires a selected option. Busy text names submission, errors remain visible, and closed requests display a read-only explanation.

**The First Valid Response Rule.** The first valid desktop or phone answer wins. Closed or expired requests must not look actionable; disconnected answers are not silently queued. The interface explicitly tells the user to reconnect and check the current request. Tool approval includes a command/tool-context warning and separate approval/rejection choices. Cancellation requires a native confirmation dialog.

### Connection and feedback

Connection state combines an icon, text, and a live-region semantic wrapper. Offline state says it is a saved view and exposes reconnect; color is not the only signal. Failures use `errorContainer`/`onErrorContainer` notices with retry where available. Transient success uses a Material snackbar; failure snackbars remain longer (8 seconds) and include close affordance.

### Navigation

Use the Material app bar for screen context, native Back, bottom navigation or the width-adapted rail for top-level destinations, and contextual detail routes. Source links must retain the actual session identity. The sidecar's HTML/CSS entries are isolated documentation-panel translations only, not shipping components, Android measurements, or a browser acceptance baseline.

## Do's and Don'ts

### Do:
- **Do** use Material color roles and preserve both authored brightness schemes.
- **Do** keep native text scaling, wrapping, semantic labels, and minimum 48dp touch targets.
- **Do** show connection, request status, provenance, and freshness in words as well as visual cues.
- **Do** distinguish durable project memory from live session activity and link to its source when available.
- **Do** honor Remove animations in custom route transitions.

### Don't:
- **Don't** convert these dp/sp records into CSS layout rules for the Android app.
- **Don't** replace flat project rows with a cramped terminal or uniform dashboard-card grid.
- **Don't** add decorative glow, glass, gradients, or generated photography to this native working surface.
- **Don't** make closed or disconnected requests appear submittable or imply offline answers are queued.
- **Don't** claim tablet, physical-device, TalkBack, or motion verification from phone screenshots alone.
