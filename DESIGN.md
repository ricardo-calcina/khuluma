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
  menu-gap: 14px
  stats-inset: 20px
components:
  button: {}
  picker: {}
  shortcut-recorder: {}
  menu-panel: {}
---

# Khuluma Design System

## Overview

### Creative North Star

A small Mac utility you open for an answer and close immediately. A shallow, arrowless daily readout leads to the original Stats view. Settings is a secondary destination behind a native titlebar gear. Precision and familiar Mac behavior carry the identity.

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

System body, callout and caption styles carry controls and explanations. Semibold 24-point system numerals carry compact usage; the original Stats figures keep their rounded 26-point bold type. Monospaced digits prevent count movement. Keep sentence case for actions.

## Layout

MenuPanel owns the 400-point panel width, 16-point inset and 14-point row gap. A quiet Today caption replaces the product heading. Three aligned metric columns show words, dictations and streak provisionally; the final metric choice remains open. A single divider separates three icon actions: open the app, Settings and Quit. Model and shortcut belong only in Settings. Warnings and recovery actions expand the panel only when applicable.

StatsWindowController owns the native unified compact toolbar: trailing gear on Stats, leading Back on Settings. No content-level tabs or navigation header. The window starts at the original Stats content size, 560 by 634 points, and can resize down to 560 by 420. Stats retains its established 560-point layout in a bounded ScrollView. Settings uses the native grouped Form and its system scrolling. Both destinations remain reachable in a short window.

## Elevation & Depth

StatusDropdownController hosts one SwiftUI view inside an NSMenuItem and assigns its NSMenu to the status item, following the working Sys Stats implementation. macOS owns the glass, corners, shadow, position and tracking. There is no pointer, custom gap, window positioning or mouse monitor. Click the icon to open, click it again or elsewhere to close, and Escape dismisses. Native placement takes priority over forced centering. The main window uses system chrome and grouped form surfaces.

## Shapes

Use system control shapes. Existing chart cells retain their small rounded corners and the existing 8-point notice radius. Use hairline native dividers for grouping.

## Components

### Foundational visual states

Use native disabled, focus, pressed, selected and hover states. Loading uses a system ProgressView or reserved en-dash metric values. Errors stay in context with an explanation and retry route; cached stats remain visible if refresh fails.

### Buttons and actions

Native titlebar toolbar items, icon-only menu footer controls and native form controls. Menu icons have a 32-by-28-point target, semantic hover and pressed surfaces, and a keyboard focus outline. The shortcut recorder is a compact key button; capture instructions appear while recording. Icon-only controls have accessible labels and help. Quit stays separate from opening the app. Recovery/discard actions retain their existing deliberate app flow.

### Navigation and data display

Stats is the home destination. Its gear and Command-comma open Settings; Back, Command-left-bracket or Escape return to Stats. Command-W closes either destination; Escape on Stats closes the window. StatusMenu and its isolated preview share the native menu container. StatsModel observes the ledger only while a surface is open; it has no polling loop. Menu updates and size invalidation use common run loop modes so they continue during menu tracking.

### Forms and overlays

SettingsModel owns authoritative config, save-in-progress and inline save/error feedback. CLIBridge writes through the CLI's validated settings command; the UI never writes TOML itself. Saves are immediate and reversible; disable relevant controls while saving or recording. Native Picker owns its popup geometry, focus, keyboard selection and collision behavior. Native Form owns field layout and scrollbars. ShortcutRecorder owns physical key capture, Escape cancellation, Tab navigation and local event-monitor cleanup.

Choosing ElevenLabs is explicit, with an audio-upload and usage-credit notice visible before selection. Parakeet remains the default. Key availability is shown without exposing the credential. No automatic fallback uploads audio to another provider.

### Iconography

SF Symbols only. The menu icon communicates recording, processing or error. The idle microphone needs no textual Ready line. Gear and Back use standard Mac toolbar placement and accessible names.

### Motion

No decorative animation. The transient panel opens without animation. Existing Stats numeric transitions respect Reduce Motion.

### Content and data visualization

Use words the person controls: model, shortcut, sounds, Start at Login, diagnostic logs. Today means local calendar day. A missing daily ledger shows a dash, never fabricated zero usage. Streak is labelled separately from today's values. Existing Stats math and coverage explanations remain authoritative.

## Do's and Don'ts

- Do keep configuration details in Settings and the menu focused on glanceable usage.
- Do preserve the original Stats layout and use the native titlebar for secondary navigation.
- Do keep recovery actions reachable whenever a recording needs attention.
- Don't display routine readiness or local daemon internals as permanent menu rows.
- Don't treat a successful config write as evidence of a live cloud transcription.
