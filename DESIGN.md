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
  light-primary: "#292e37"
  light-on-primary: "#ffffff"
  light-primary-container: "#d5dde8"
  light-on-primary-container: "#23272f"
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

**Creative North Star: Graphite workbench.** The explicitly requested neumorphic system uses graphite in dark mode, fog in light mode and consistent top-left lighting. Dark action/focus keeps amber; light action/focus now uses the dark scheme's navy-graphite raised tone. The user-supplied Sisyphus artwork defines the Android launcher and working indicator. The product remains a Turkish-first, local-first native companion for paired-PC work and human decisions, not a marketing surface.

`mobile/lib/neumorphic.dart` owns `NeoPalette`, `NeoSurface`, `NeoInputBorder` and native button backgrounds. `mobile/lib/ui.dart` owns the Material theme, semantic roles and route transitions; screen-specific composition remains in the native screen files. All dimensions here are logical dp; text follows Android system scaling, expressed in sp terms. This is source-derived documentation, not native visual acceptance. Acceptance and historical evidence belong in [the canonical implementation report](Raporlar/2026-11-13-butunsel-neumorphic-ui.md); earlier screenshots do not establish acceptance of this redesign.

## Colors

The frontmatter records authored constants. `ColorScheme.fromSeed` uses `#a87920` in dark appearance and `#292e37` in light appearance; `ui.dart` overrides the recorded roles. No wallpaper-derived Dynamic Color is implemented. Foregrounds resolve through the active semantic pairs. Primary/primary-container in light appearance use navy and a cool muted container, not the former brown/amber pair. Dark semantic pairs are unchanged.

Base/raised/inset share the existing neutral ramp. Primary means action, selection or focus, never an all-screen wash. Error notices retain generated `errorContainer`/`onErrorContainer` and explanatory words. Card depth uses neutral surface steps and offset shadows, not accent-filled status tiles.

## Application mark

Android uses the supplied cheerful Sisyphus/person-and-boulder image. Original pixels and transformation provenance live under `mobile/branding/assets`; legacy density icons retain the whole supplied composition. Adaptive foreground and Android13 monochrome derive from the actual isolated art with safe margins and an opaque warm source-matched backdrop. Native splash resolves the same new launcher with no artificial delay. The existing small notification glyph stays unchanged: the detailed illustration is not substituted for a native status-bar alpha glyph.


## Typography

Use native Roboto and `Typography.material2021(platform: TargetPlatform.android)`, with no remote font dependency or parallel fixed-size type scale. Screen headings use headline roles, sections/project names use title roles, reading uses body roles and provenance/status use label roles. App-bar titles and project titles use weight 600. Extended reading and system-monospace editor content use line-height 1.5 where authored. Preserve wrapping, selectable reading content and system text scale; do not shrink text to maintain a composition.

## Layout

Phone Home is a compact operating screen: symmetric app bar with reference72×48dp theme switch left, centered title/connection and Settings right; search and joined filters flow into upright layered project cards and an N-position48dp rail. Front cards are lighter raised neutral surfaces; back cards are darker inset tones, combined with restrained translation/scale/opacity. Native titleLarge (22sp) and expanded headlineSmall (24sp), weight600, make project names lead. The body is only a bounded continuation preview from the newest available memory/activity; no project-goal fallback, generated summary, session inventory or status-copy stack. Missing continuity is stated honestly. Pin/open semantics and full project details remain.

Working project cards lead the heading with the supplied64×64dp Sisyphus GIF,12dp before the project name. The trailing pin and wrapping title keep their native roles. Continuation text now occupies a separate full-width row with no duplicate GIF beside it. Session-list rows retain their existing small indicator; working-state, route/lifecycle/TickerMode and reduced-motion gates are unchanged.

Tümü/Sabitlenen keep the selected project's complete session history. Canlı combines all projects' connected writer sessions whose authoritative workState is running/background; card selection does not filter that list. Each live row names its project. Settled/human_wait/queued/closed/disconnected/active-unbridged are excluded; host connection loss empties Canlı rather than presenting cached state as live. Project detail retains history and applies the same actual-work predicate to its Canlı filter. Bottom Projects/New session(action)/Inbox composition and form/Back/draft behavior remain unchanged.

Bottom navigation now joins the active body directly, without an8dp gap or12dp full-width connector band. Upward tabs keep their existing selected rounded form/concave shoulders, open to the body at its center with no closing stroke or shadow. Inactive columns remain recessed. The outer project body no longer closes with rounded bottom corners; its separate inset session-reading panel keeps its shape. Inbox extends the matching neutral carrier to the same boundary. Active filter tints resolve identically in the content and bottom selected tab; top filters' downward joins are unchanged. Navigation stays fixed and owns the Android bottom safe area, while content owns no duplicate bottom inset. New session remains a separate action/route.

The composer input/send row remains anchored above the resized safe-area/IME bottom; ancillary controls and attachments may scroll independently. Short-screen headers/notices must not collapse the editable row. Preserve draft ownership, multiline growth, selection, keyboard submission rules and acknowledged-version clearing.

## Elevation & Depth

One lighting model applies across the app. Raised surfaces use a lower-right shadow at (4,4), blur radius 10, alpha .7 and upper-left highlight at (-4,-4), blur radius 10, alpha .55. Compact controls use ±2 offsets and blur radius 5 with the same alpha. Inset surfaces clip an even-odd interior shadow: shadow at (3,3), alpha .6, highlight at (-3,-3), alpha .65, with native mask-blur sigma 3. Sigma is not a CSS box-shadow blur radius. Flat surfaces have no depth shadows. Palette highlight/shadow colors resolve by brightness.

Existing route motion remains 220ms forward/180ms reverse, Cubic(.16,1,.3,1), fade plus horizontal offset .025 of child width (.045 for checkpoints). `disableAnimations` returns the untransformed child with zero custom duration. No new depth animation is prescribed.

The finite upright stack caches at most five actual neighboring cards. No Play/Pause/Restart button remains. Seven seconds after the last input/release, a1200ms automatic translation/scale/opacity step uses Cubic(.77,0,.175,1), followed by another7s dwell. The last project stops; the native rail can select an earlier project. Manual steps stay280ms Cubic(.16,1,.3,1); keyboard/assistive/reduced choices are immediate. Held pointer/key, scrolling, text input/IME, covered route, hidden/offscreen/lifecycle and motion preferences suspend auto advance; reopening a gate starts a full fresh dwell, without catchup. The local supplied12-frame/1680ms GIF is decoded incrementally at256px and only moves for actual work under lifecycle/TickerMode/route/reduced-motion gates.

## Shapes

Use 12dp for chips/text buttons, 16dp for fields/buttons/rows/menus, default 20dp for `NeoSurface`, and 24dp for dialogs and sheet top corners. These are authored roles, not a mandate to replace every SDK shape. Native radio, checkbox and other Material control geometry remains native. App bars have zero elevation/scrolled-under elevation; transparent tint avoids a competing lighting layer.

## Components

Filled/outlined/icon buttons preserve native callbacks, focus, ink and text/icon foreground inheritance through NeoSurface. Minimum52dp primary and48dp compact targets remain. Resting raised/pressed inset/disabled flat backgrounds use the existing builder. Enabled filled foreground uses onPrimary against dark amber or light navy with at least4.5:1 contrast. Focus and disabled roles stay explicit; no local label-color overrides.

Fields use true NeoInputBorder inset painting,16dp padding/radius, resting outline-variant and2dp primary focus borders. Native labels, accessibility, editing/IME/selection/validation stay unchanged. Cursor/handles use the active primary and selection alpha.24; the persistent message-editor name and draft boundaries remain.

Navigation uses inset indicators and the current primary selected label/icon. Chips, menus/dialogs/sheets/snackbars retain shared native roles, surfaces and dismissals. The existing native sun/moon control is preserved; light navy is not a replacement visual system.

**First valid response and trust.** The first valid desktop or phone answer wins. Requests are actionable only while pending, connected, valid and not submitting. Closed/expired requests stay read-only; offline answers are not silently queued. Tool decisions retain command/context warnings and separate approve/reject actions; cancellation uses native confirmation. Status, freshness, saved/offline state and failure are conveyed in words, not color alone.

Preserve source-session, project, branch and paired-PC identity. Durable project memory remains distinct from live activity; a finished agent turn is not project completion. File/diff inspection is read-only, not implicit stage/reset/commit. Local Markdown does not fetch remote images or follow arbitrary URLs; remote/absolute references remain copy-only and navigable project paths retain host-enforced confinement. Diagnostics stay redacted by default; surface styling grants no new permissions or disclosure.

## Do's and Don'ts

- Do use the active palette and Material semantic pairs, native Roboto roles and system scale.
- Do keep meaningful touch targets, labels, focus, readable flat content and real source/freshness context.
- Do retain the existing reduced-motion and inactive/offscreen stop rules.
- Don't add colored glows, wallpaper claims, unrelated decorative imagery or loops beyond the explicitly supplied working GIF and idle-driven finite project movement.
- Don't replace native semantics, response gating, draft/IME behavior or privacy boundaries with decorative controls.
- Don't treat this record, sidecar previews or historical captures as current native acceptance. Physical-device performance, TalkBack, large-font, landscape/tablet and reduced-motion runtime results must be established in the canonical report, not inferred here.
