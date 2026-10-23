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
  menu-inset: 18px
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

A small Mac utility you open for an answer and close immediately. The distinctive element is a wide, three-column daily readout, paired with the actual dictation shortcut and current model.

### Product context and register

- Audience and job: the person dictating throughout the day; see usage and adjust the app without editing TOML.
- Market and language: English macOS utility; no Japan-specific market or locale contract. Format dates and numbers with the user's system locale.
- Usage scene: keyboard-led desktop use, with a small menu panel and one full window.
- Register: product utility. Familiar native behavior takes precedence over decorative styling.
- Restraint: no permanent Ready badge, marketing copy, decorative cards or custom font downloads.
- Anti-references: tall command menus and web dashboards with oversized branding.
- Runtime ownership: SwiftUI/AppKit semantic styles remain canonical. This file documents their use; it does not generate CSS or duplicate the system palette.

## Colors

Use primary and secondary text, windowBackgroundColor, quaternary dividers, system accent for charts and selection, and orange with a text warning for recoverable problems. The operating system owns exact values, dark mode, increased contrast and control focus colors. No hardcoded hex palette.

## Typography

System body, callout and caption styles carry controls and explanations. Rounded, semibold 25-point numerals carry compact usage; the existing Stats figures use rounded 26-point bold type. Monospaced digits prevent count movement. Shortcut text is monospaced. Keep sentence case for actions.

## Layout

MenuPanel owns the 440-point panel width, 18-point inset and 14-point row gap. Three equal metric columns are separated by native dividers. Model and shortcut controls share one row. Footer contains Open Khuluma, Settings and Quit. Warnings and recovery actions expand the panel only when applicable.

AppView owns a 600-point minimum width, segmented Stats/Settings navigation and a 460-point minimum height. Stats keeps its established 560-point content width inside its own ScrollView. Settings uses the native grouped Form and its system scrolling. The window starts at 600 by 670 points and can resize; either tab's long content remains reachable.

## Elevation & Depth

The native transient NSPopover supplies anchoring, dismissal and depth. The main window uses the system background and grouped form surfaces. Avoid extra shadows or nested floating cards.

## Shapes

Use system control shapes. Existing chart cells retain their small rounded corners and the existing 8-point notice radius. Use hairline native dividers for grouping.

## Components

### Foundational visual states

Use native disabled, focus, pressed, selected and hover states. Loading uses a system ProgressView or reserved en-dash metric values. Errors stay in context with an explanation and retry route; cached stats remain visible if refresh fails.

### Buttons and actions

Native bordered buttons for model and shortcut, borderless footer controls, text buttons in Settings. Icon-only controls have accessible labels and help. Quit stays separate from Open Khuluma. Recovery/discard actions retain their existing deliberate app flow.

### Navigation and data display

AppView owns segmented Stats/Settings navigation. StatusMenu owns the transient menu panel. StatsModel owns usage loading and observes the ledger only while either surface is open; it has no polling loop. Opening model or shortcut goes to Settings. Escape and Command-W close the main window.

### Forms and overlays

SettingsModel owns authoritative config, save-in-progress and inline save/error feedback. CLIBridge writes through the CLI's validated settings command; the UI never writes TOML itself. Saves are immediate and reversible; disable relevant controls while saving or recording. Native Picker owns its popup geometry, focus, keyboard selection and collision behavior. Native Form owns field layout and scrollbars. ShortcutRecorder owns physical key capture, Escape cancellation, Tab navigation and local event-monitor cleanup.

Choosing ElevenLabs is explicit, with an audio-upload and usage-credit notice visible before selection. Parakeet remains the default. Key availability is shown without exposing the credential. No automatic fallback uploads audio to another provider.

### Iconography

SF Symbols only. The menu icon communicates recording, processing or error. The idle microphone needs no textual Ready line. Model/shortcut remain text-labelled.

### Motion

No decorative animation. The transient panel opens without animation. Existing Stats numeric transitions respect Reduce Motion.

### Content and data visualization

Use words the person controls: model, shortcut, sounds, Start at Login, diagnostic logs. Today means local calendar day. A missing daily ledger shows a dash, never fabricated zero usage. Streak is labelled separately from today's values. Existing Stats math and coverage explanations remain authoritative.

## Do's and Don'ts

- Do keep the current shortcut and actual effective model visible together.
- Do keep recovery actions reachable whenever a recording needs attention.
- Don't display routine readiness or local daemon internals as permanent menu rows.
- Don't treat a successful config write as evidence of a live cloud transcription.
