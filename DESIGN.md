---
version: alpha
name: Khuluma
description: A quiet native macOS dictation utility with useful usage at a glance.
omitted:
  - section: colors
    reason: AppKit and SwiftUI semantic system colors own the light, dark and accessibility palettes.
typography:
  sans:
    fontFamily: SF Pro, system-ui
  mono:
    fontFamily: SF Mono, ui-monospace
rounded:
  DEFAULT: 8px
spacing:
  menu-inset: 16px
  menu-gap: 10px
  stats-inset: 20px
  stats-vertical-inset: 12px
  stats-gap: 12px
components:
  button: {}
  picker: {}
  shortcut-recorder: {}
  menu-panel: {}
---

# Khuluma Design System

## Overview

### Creative North Star

A small Mac utility you open for an answer and close immediately. A shallow, arrowless lifetime readout leads to a quiet Stats window with the same three figures and daily activity. Settings is a secondary destination behind a small native titlebar gear. Precision and familiar Mac behavior carry the identity.

### Product context and register

- Audience and job: the person dictating throughout the day; see usage and adjust the app without editing TOML.
- Market and language: English macOS utility; no Japan-specific market or locale contract. Format dates and numbers with the user's system locale.
- Usage scene: keyboard-led desktop use, with a small menu panel and one full window.
- Register: product utility. Familiar native behavior takes precedence over decorative styling.
- Restraint: no permanent Ready badge, marketing copy, decorative cards or custom font downloads.
- Anti-references: tall command menus and web dashboards with oversized branding.
- Runtime ownership: SwiftUI/AppKit semantic styles remain canonical. This file documents their use; it does not generate CSS or duplicate the system palette.

## Colors

Use primary and secondary text, native menu material, windowBackgroundColor, quaternary dividers and system accent for charts and selection. Warnings use a labelled symbol and legible primary text. The operating system owns exact values, dark mode, increased contrast, reduced transparency and control focus colors. No hardcoded hex palette.

## Typography

System body, callout and caption styles carry controls and explanations. Semibold 22-point system numerals carry compact usage; Stats uses 28-point semibold figures. Monospaced digits prevent count movement. Keep sentence case for actions.

## Layout

MenuPanel owns the 400-point panel width, 16-point horizontal and 12-point vertical content insets, and 10-point row gap. A quiet All time caption replaces the product heading. Three equal, centered columns show Total words, Time saved and Average WPM. A single divider separates the footer: open the app on the left; a mini Auto-send switch, Settings and Quit on the right. Auto-send is the one dictation setting in the menu because it changes per task. The footer uses 12-point horizontal and 4-point vertical padding. Model and shortcut belong only in Settings. Warnings and recovery actions expand the panel only when applicable.

StatsWindowController owns the native unified compact toolbar: trailing Usage information, Refresh and Settings on Stats, leading Back on Settings. All three Stats actions use 13-point symbols in 28-by-24-point small native buttons. No content-level tabs or navigation header. The window starts at 560 by 634 points and can resize down to 560 by 420. Stats has three groups: centered lifetime figures, Activity, and records/recording totals/word progress. The All time caption has a 6-point gap; content uses 20-point horizontal/12-point vertical insets. Four flexible gaps, at least 10 points each, share spare viewport height around the two main dividers. Records show best day, longest take and longest streak without trophy icons, New badges or competitive framing. Recording time clearly separates all-time and today. Normal content fills the starting window without scrolling; its bounded ScrollView remains a fallback for short windows and additional notices. Settings uses the native grouped Form and its system scrolling. Both destinations remain reachable in a short window.

## Elevation & Depth

StatusDropdownController hosts one SwiftUI view inside an NSMenuItem and assigns its NSMenu to the status item, following the working Sys Stats implementation. macOS owns the glass, corners, shadow, position and tracking. There is no pointer, custom gap, window positioning or mouse monitor. Click the icon to open, click it again or elsewhere to close, and Escape dismisses. Native placement takes priority over forced centering. The main window uses system chrome and grouped form surfaces.

## Shapes

Use system control shapes. Existing chart cells retain their small rounded corners and the existing 8-point notice radius. Use hairline native dividers for grouping.

## Components

### Foundational visual states

Use native disabled, focus, pressed, selected and hover states. Loading uses a system ProgressView or reserved en-dash metric values. Errors stay in context with an explanation and retry route; cached stats remain visible if refresh fails.

### Buttons and actions

Native titlebar toolbar items, icon-only menu footer controls and native form controls. Menu icons have a 28-by-24-point target, semantic hover and pressed surfaces, and native keyboard focus feedback. Opening the menu clears automatic initial button focus. The shortcut recorder is a compact key button; capture instructions appear while recording. Icon-only controls have accessible labels and help. Quit stays separate from opening the app. Recovery/discard actions retain their existing deliberate app flow.

### Navigation and data display

Stats is the home destination. Its gear and Command-comma open Settings; Back, Command-left-bracket or Escape return to Stats. Refresh and Command-R reload Stats. Usage information opens a compact transient native popover with coverage dates, privacy and the last update time, replacing the permanent footer. Refresh failures remain visible in the main content as well. Escape dismisses usage information first; otherwise Escape on Stats closes the window. Command-W closes either destination. StatusMenu and its isolated preview share the native menu container. StatsModel observes the ledger only while a surface is open; it has no polling loop. Menu updates and size invalidation use common run loop modes so they continue during menu tracking.

### Forms and overlays

SettingsModel owns authoritative config, save-in-progress and inline save/error feedback. CLIBridge writes through the CLI's validated settings command; the UI never writes TOML itself. Saves are immediate and reversible; disable dictation controls while saving or recording. The Appearance picker and the Paste without sending key stay available and store their app-only choices in the existing preferences domain. Native Picker owns its popup geometry, focus, keyboard selection and collision behavior. Native Form owns field layout and scrollbars. ShortcutRecorder owns physical key capture, Escape cancellation, Tab navigation and local event-monitor cleanup.

Choosing ElevenLabs is explicit, with an audio-upload and usage-credit notice visible before selection. Parakeet remains the default. Key availability is shown without exposing the credential. No automatic fallback uploads audio to another provider.

Cleanup & vocabulary is part of the existing Settings Form: an immediate cleanup switch, a native repetition Picker and Manage Vocabulary. Vocabulary opens a 560-by-660-point native sheet. VocabularyView owns the native segmented section Picker (Fillers, Brands, Other words, Examples), bounded List, labelled entry fields, local search with Clear, and native open/save file panels. VocabularyModel owns the draft, selection, validation feedback and Undo; CLIBridge and the CLI own validated persistence. Keep footer actions visible, preserve fields on errors, and block changing section/selection until an entry is added, updated or cleared. All four sections share these controls. Examples rows add a pass/fail symbol; the caption line under the fields shows the draft's result for the Said text (with Use as Expected) or, for a selected failing example, the one-rule fix (Add Rule). No new color or typography tokens are introduced.

Import validates one JSON document and presents section totals plus added/changed/removed counts before replacing the draft. Save Changes commits the draft; Cancel/Escape confirms discard only when necessary. Reload confirms before losing edits. Remove affects the draft and offers Undo. Export says Export Draft when changes are unsaved. Saves retain an exact previous-file backup and reject a stale revision, keeping the draft available for export and retry. The first save retains the old text vocabulary intact and makes vocabulary.json the single active document. The isolated UI preview uses only in-memory vocabulary; sample actions never discover the daily CLI.

### Iconography

Interface controls use SF Symbols. The menu icon uses custom cursed-speech templates for Ready, Recording and Processing, with the existing SF Symbol for error. The idle glyph needs no textual Ready line. Gear and Back use standard Mac toolbar placement and accessible names.

The app icon uses the selected raised Inumaki-inspired direction: black enamel on ivory for light appearance, ivory enamel on charcoal for dark. The compact silhouette keeps a central mouth, two raised rings with solid pupils and short diagonal connections. Approved artwork and legacy production exports live in `assets/icons/app/`; `tools/make-khuluma-icons.swift` applies a shared raster crop and rounded mask. Legacy PNG/ICNS exports include the native canvas inset. `assets/icons/AppIcon.icon/Assets/` uses full-canvas derivatives so Icon Composer supplies that outer container once. Explicit default/dark raster specializations retain the approved raised materials; additional glass, specular, shadow and translucency effects are disabled.

The bundle stages the compiled `Assets.car` and declares `CFBundleIconName=AppIcon` for macOS 26+ appearance selection, alongside the ICNS fallback. `tools/compile-khuluma-icon.sh` and the icon-only workflow compile and verify the catalog with Xcode 26+. Build 347 verified the full-canvas artwork and Finder light/dark switching. Routine menu updates reuse that verified catalog. Icon style is Dark → Auto and general appearance remains Auto. Reproduction and artifact provenance live in `assets/icons/README.md` and `assets/icons/app/catalog-build.json`.

The native menu uses black-and-clear 28-by-20-point PDF canvases with artwork up to 18 points tall. StatusMenu caches both themes and owns the fixed 36-point slot, template tint and accessible status label. Ready keeps the approved brand glyph in both themes. Cursed speech uses a round, 14.5-point fanged mouth with voice strokes for Recording and two turning arcs around fang marks for Processing/Finishing. Full emblem keeps the side rings and changes the centre for those states. Errors retain the existing status symbol. macOS supplies light/dark/selected tint. Raised shading belongs only in the app icon.

Settings → Appearance → Menu bar icons switches immediately between Cursed speech (the default, set 1) and Full emblem (set 2), including during Recording or Processing. The choice persists across launches without changing CLI configuration. Both source sets remain in `assets/icons/menu-bar/concepts/`. Finishing is a visual name for the existing processing/delivery interval, including paste and optional send-key events. Phase timing, overlapping-take priority, labels and error handling stay unchanged.

### Motion

The Processing fang seal rotates slowly clockwise, one revolution every four seconds, as functional work-in-progress feedback. Cursed speech rotates the seal; Full emblem rotates only the central seal while its two side rings and connectors stay fixed. The native button and selected background stay still. A timer in common run loop modes keeps it moving while the native menu is open. Rotation uses elapsed monotonic time, so repeated Processing updates and theme switches do not restart it. Ready, Recording and Error remain static; leaving Processing stops its timer immediately. Reduce Motion keeps each theme's canonical seal still and reacts to preference changes. Existing Stats numeric transitions also respect Reduce Motion. The transient panel opens without animation; no decorative motion is added.

### Content and data visualization

Use words the person controls: model, shortcut, sounds, Start at Login, diagnostic logs. Both summaries use lifetime totals. Time saved is visibly approximate and retains signed values if dictation took longer than the typing estimate; help explains the configured typing speed and full delivery time. Average WPM includes recording pauses. Recording time measures audio from delivered dictations, not estimated time saved. Records cover all stored daily history, independently of the selected Activity range; missing or partial daily coverage remains explicit. Missing values show a dash, never fabricated zero usage. Daily activity and streak remain separate from lifetime figures. The 8-point capsule milestone bar fills from zero to the next word target: 51,213 of 100,000 is 51.2%, matching 48,787 remaining. Keep a quiet inline acknowledgement when a newly reached target is observed. Existing Stats math and coverage explanations otherwise remain authoritative.

## Do's and Don'ts

- Do keep configuration details in Settings and the menu focused on glanceable usage.
- Do give the three lifetime figures priority, with activity, records and word progress underneath; use the native titlebar for secondary navigation.
- Do keep recovery actions reachable whenever a recording needs attention.
- Don't display routine readiness or local daemon internals as permanent menu rows.
- Don't treat a successful config write as evidence of a live cloud transcription.
