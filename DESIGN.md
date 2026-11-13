---
name: Omputer Android
description: A local-first native working companion in graphite and fog neumorphic materials.
colors:
  scheme-seed: "#a87920"
  dark-base: "#23272f"
  dark-raised: "#292e37"
  dark-inset: "#20242b"
  dark-highlight: "#383e49"
  dark-shadow: "#13161c"
  dark-text: "#f1f3f5"
  dark-secondary: "#c0c6cf"
  dark-primary: "#f3ca68"
  dark-on-primary: "#272016"
  dark-primary-container: "#463c28"
  dark-on-primary-container: "#ffe3a2"
  dark-outline: "#8e98a5"
  dark-outline-variant: "#454e5b"
  light-base: "#e8edf2"
  light-raised: "#eef2f6"
  light-inset: "#e2e8ee"
  light-highlight: "#ffffff"
  light-shadow: "#bdc6d0"
  light-text: "#252c35"
  light-secondary: "#505b68"
  light-primary: "#775500"
  light-on-primary: "#ffffff"
  light-primary-container: "#f1dfb5"
  light-on-primary-container: "#4a370d"
  light-outline: "#677482"
  light-outline-variant: "#bdc7d1"
typography:
  native:
    fontFamily: Roboto
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
  chip-text-button: "12dp"
  field-button-row-menu: "16dp"
  surface: "20dp"
  dialog-sheet: "24dp"
spacing:
  compact: "8dp"
  related: "12dp"
  control: "16dp"
  container: "20dp"
  page: "24dp"
shadows:
  raised:
    shadowOffset: "4dp 4dp"
    highlightOffset: "-4dp -4dp"
    blurRadius: "10dp"
    shadowAlpha: 0.7
    highlightAlpha: 0.55
  compact:
    shadowOffset: "2dp 2dp"
    highlightOffset: "-2dp -2dp"
    blurRadius: "5dp"
    shadowAlpha: 0.7
    highlightAlpha: 0.55
  inset:
    shadowOffset: "3dp 3dp"
    highlightOffset: "-3dp -3dp"
    maskBlurSigma: "3dp"
    shadowAlpha: 0.6
    highlightAlpha: 0.65
components:
  button:
    width: "48dp minimum"
    height: "52dp minimum"
    rounded: "{rounded.field-button-row-menu}"
  compact-button:
    width: "48dp minimum"
    height: "48dp minimum"
  input:
    rounded: "{rounded.field-button-row-menu}"
    padding: "16dp"
---

# Design System: Omputer Android

## Overview

**Creative North Star: Graphite workbench.** The explicitly requested whole-app neumorphic redesign uses graphite in dark mode and fog in light mode, one amber action accent, and consistent top-left lighting. This replaces the previous visual world rather than layering another style onto it. The product remains a Turkish-first, local-first native companion for paired-PC project continuity, conversations and human decisions—not a cloud dashboard or marketing surface.

`mobile/lib/neumorphic.dart` owns `NeoPalette`, `NeoSurface`, `NeoInputBorder` and native button backgrounds. `mobile/lib/ui.dart` owns the Material theme, semantic roles and route transitions; screen-specific composition remains in the native screen files. All dimensions here are logical dp; text follows Android system scaling, expressed in sp terms. This is source-derived documentation, not native visual acceptance. Acceptance and historical evidence belong in [the canonical implementation report](Raporlar/2026-11-13-butunsel-neumorphic-ui.md); earlier screenshots do not establish acceptance of this redesign.

## Colors

The frontmatter records authored constants, not an invented tonal ramp. `ColorScheme.fromSeed` uses `#a87920` at the selected brightness; `ui.dart` overrides the recorded roles. There is no wallpaper-derived Dynamic Color implementation. Resolve every foreground/background through the active theme rather than transplanting a dark pair into light mode.

`surface`, scaffold and canvas use base; low/high surface containers use raised; lowest/highest containers and secondary containers use inset. `onSurface` and `onSecondaryContainer` use text; `onSurfaceVariant` and secondary use secondary text. `onSecondary` uses base. Tertiary shares amber primary with base as its foreground. Primary containers use the authored amber-muted pair; unoverridden roles, including errors, remain generated Material roles. Amber means action, selection or focus—not generic decoration. Error notices use `errorContainer`/`onErrorContainer` and retain explanatory text.

## Typography

Use native Roboto and `Typography.material2021(platform: TargetPlatform.android)`, with no remote font dependency or parallel fixed-size type scale. Screen headings use headline roles, sections/project names use title roles, reading uses body roles and provenance/status use label roles. App-bar titles and project titles use weight 600. Extended reading and system-monospace editor content use line-height 1.5 where authored. Preserve wrapping, selectable reading content and system text scale; do not shrink text to maintain a composition.

## Layout

Compact navigation has Projeler, Gelen kutusu and Ayarlar; at available width 720dp it becomes a labeled native NavigationRail. This width rule is not proof of tablet acceptance. Common gutters are 24dp, with 8/12/16/20/24dp spacing for increasingly separated groups. Section-heading padding remains left 24, top 28, right 16, bottom 12dp.

Keep long transcripts, files, diffs and memory on quiet flat reading planes. Use raised surfaces for actionable groups and inset surfaces for entry/selection, not a shadow around every paragraph. The project ring keeps real project-ID ordering; selected-project text and session actions remain outside the transform. Search, empty/loading/error states and offline saved-view labels represent actual data, never demonstration content.

The composer input/send row remains anchored above the resized safe-area/IME bottom; ancillary controls and attachments may scroll independently. Short-screen headers/notices must not collapse the editable row. Preserve draft ownership, multiline growth, selection, keyboard submission rules and acknowledged-version clearing.

## Elevation & Depth

One lighting model applies across the app. Raised surfaces use a lower-right shadow at (4,4), blur radius 10, alpha .7 and upper-left highlight at (-4,-4), blur radius 10, alpha .55. Compact controls use ±2 offsets and blur radius 5 with the same alpha. Inset surfaces clip an even-odd interior shadow: shadow at (3,3), alpha .6, highlight at (-3,-3), alpha .65, with native mask-blur sigma 3. Sigma is not a CSS box-shadow blur radius. Flat surfaces have no depth shadows. Palette highlight/shadow colors resolve by brightness.

Existing route motion remains 220ms forward/180ms reverse, Cubic(.16,1,.3,1), fade plus horizontal offset .025 of child width (.045 for checkpoints). `disableAnimations` returns the untransformed child with zero custom duration. No new depth animation is prescribed.

The existing perspective project ring retains its 20-second revolution, play/pause, drag interruption and previous/next controls. Text entry pauses rotation; keyboard selection is immediate. Reduced motion/accessibility navigation use static selection; route inactivity and app inactivity suspend ticking. The speeder avatar only indicates a live connection with a connected writer and `workState` running/background. Human-wait, settled and disconnected states never animate merely because a process exists. Reduced motion uses a static silhouette with text; offscreen/inactive ticking stops. These are retained user-requested exceptions, not permission to add decorative loops.

## Shapes

Use 12dp for chips/text buttons, 16dp for fields/buttons/rows/menus, default 20dp for `NeoSurface`, and 24dp for dialogs and sheet top corners. These are authored roles, not a mandate to replace every SDK shape. Native radio, checkbox and other Material control geometry remains native. App bars have zero elevation/scrolled-under elevation; transparent tint avoids a competing lighting layer.

## Components

Filled and outlined buttons keep native callbacks, semantics, focus and ink response. Minimum size is 48×52dp; compact/icon and text buttons are at least 48×48dp. Filled/outlined/icon button backgrounds use `backgroundBuilder`: resting raised, pressed/selected inset, disabled flat. Enabled filled actions use amber and its on-primary pair. Focus uses the primary border; disabled treatment remains explicit, with the authored muted foreground and border rather than an invented universal opacity.

Fields use true `NeoInputBorder` inset painting, 16dp padding/radius, a resting outline-variant border and 2dp amber focus border. Error borders use native error roles; disabled outline alpha is .5. Native floating labels, accessible names, editing, IME, selection and validation remain intact. Cursor/handles use amber; selection uses amber alpha .24. The message editor retains its persistent “OMP’ye mesaj” name and native draft behavior.

Navigation uses inset indicators and amber selected labels/icons without replacing native destinations or Back. Chips use raised/inset/base for resting/selected/disabled, radius 12 and 8dp padding, with a native selection checkmark. Menus use raised 16dp surfaces; dialogs and sheets use raised 24dp surfaces and native dismissal/confirmation behavior. Snackbars use text-colored backgrounds with base-colored content; dividers use outline-variant alpha .65.

**First valid response and trust.** The first valid desktop or phone answer wins. Requests are actionable only while pending, connected, valid and not submitting. Closed/expired requests stay read-only; offline answers are not silently queued. Tool decisions retain command/context warnings and separate approve/reject actions; cancellation uses native confirmation. Status, freshness, saved/offline state and failure are conveyed in words, not color alone.

Preserve source-session, project, branch and paired-PC identity. Durable project memory remains distinct from live activity; a finished agent turn is not project completion. File/diff inspection is read-only, not implicit stage/reset/commit. Local Markdown does not fetch remote images or follow arbitrary URLs; remote/absolute references remain copy-only and navigable project paths retain host-enforced confinement. Diagnostics stay redacted by default; surface styling grants no new permissions or disclosure.

## Do's and Don'ts

- Do use the active palette and Material semantic pairs, native Roboto roles and system scale.
- Do keep meaningful touch targets, labels, focus, readable flat content and real source/freshness context.
- Do retain the existing reduced-motion and inactive/offscreen stop rules.
- Don't add colored glows, wallpaper claims, decorative imagery, new looping motion or a competing aesthetic.
- Don't replace native semantics, response gating, draft/IME behavior or privacy boundaries with decorative controls.
- Don't treat this record, sidecar previews or historical captures as current native acceptance. Physical-device performance, TalkBack, large-font, landscape/tablet and reduced-motion runtime results must be established in the canonical report, not inferred here.
