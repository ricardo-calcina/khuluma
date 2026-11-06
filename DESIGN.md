---
version: alpha
name: Khuluma
description: A quiet native macOS dictation utility with useful usage at a glance.
colors:
  canvas-light: "#FFFFFF"
  canvas-dark: windowBackgroundColor
  track-light: "#EFEDEB"
  rule-light: "#E5E2E0"
  ember-dark: ["#F6B44B", "#F28C38", "#EA5F2A", "#D93A26"]
  ember-light: ["#F0A432", "#EC7F1F", "#E3581E", "#CC3622"]
  accent-text-light: "#B8401A"
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
- Restraint: no permanent Ready badge, marketing copy or custom font downloads. Stats separates its sections by spacing and faint hairlines, never boxes or cards.
- Anti-references: tall command menus and web dashboards with oversized branding.
- Runtime ownership: SwiftUI/AppKit semantic styles remain canonical. This file documents their use; it does not generate CSS or duplicate the system palette.

## Colors

Text is the system primary and secondary label colour, so it follows light, dark and increased contrast. Marks are one ink, like the app icon's black line art: black on light, white on dark. Colour is the ember ramp (amber, orange, flame, red): heatmap levels 1–4, words-per-day bars, the milestone bar (amber to red) and, as the single accent, flame for selection, switches and focus. Light and dark are composed separately in `native/Sources/Khuluma/Theme.swift` (Surface, Ink, Ember, HeatColor, RingMark, Rule), not inverted.

- Dark: the window background (windowBackgroundColor), empty days and tracks at primary 0.07, hairlines at 0.1, and the ember ramp #F6B44B, #F28C38, #EA5F2A, #D93A26. Every level glows on charcoal; bars run amber to flame at 0.8, the hovered day full strength.
- Light (white, chosen 2026-11-06): canvas #FFFFFF for the window, Settings and Vocabulary, warm-neutral tracks #EFEDEB and hairlines #E5E2E0. The grey windowBackgroundColor was dropped because grey dulled the ramp and left amber at 1.5:1. The ramp is re-tuned to even OKLCH lightness steps on white (0.775, 0.705, 0.635, 0.56): #F0A432, #EC7F1F, #E3581E, #CC3622. Bars run orange to red at 0.9. Accent-coloured text uses #B8401A for 4.5:1; fills keep flame.
- Selection is a soft flame tint (0.14 light, 0.22 dark) with accent text: the Settings sidebar row, the Activity range and the title bar tabs. An ivory canvas (#FCF9F3) and an ember-tinted cream were tried for light; selectable themes are a later idea (LOG Next).

Warnings use a labelled symbol and legible primary text. The operating system owns the menu's glass, control focus rings, increased contrast and reduced transparency.

## Typography

System body, callout and caption styles carry controls and explanations. Semibold 22-point system numerals carry compact usage; Stats uses 32-point semibold rounded figures and 18-point semibold rounded highlight values, each over a 10-point medium uppercase label tracked 0.8. Monospaced digits prevent count movement. Keep sentence case for actions.

## Layout

MenuPanel owns the 400-point panel width, 16-point horizontal and 12-point vertical content insets, and 10-point row gap. There is no caption or heading: three equal, centered columns show the figures for the period chosen in Settings → Appearance → Menu figures. All time reads Total words, Time saved and Average WPM; Today reads Words today, Saved today and WPM today, using the same time-saved estimate on today's bucket. An optional 7-day strip (on by default; Show last 7 days in menu) draws words per day as ember bars (amber base to flame top, other days at 0.8) over an ink baseline, today full strength and on the right, with weekday initials. The figures match the Stats hero: a 24-point rounded semibold value over its small caps title. While recording, the mic is a white glyph on a 20-point ember-red disc and Cancel is a compact ink capsule (xmark, Cancel); Auto-send is a hand-drawn switch (flame when on, ink track when off) because AppKit draws real switches inactive inside a menu; and footer icons are ink with ink-track hover surfaces. Below them, between two full-width dividers, a native Microphone row (mic symbol, right-aligned secondary value) shows the input the next take uses and opens a native submenu: System Default naming the device it resolves to, the connected inputs, a chosen device that isn't connected (greyed, Not connected, still checked; the row then shows the default with "(Default)"), and Sound Settings…. A chosen device the recorder couldn't use (the selection didn't hold or capture wouldn't start) also shows the default with "(Default)" and a tooltip until it is chosen again or the device list changes. A choice applies from the next take; the list and row update live as devices come and go. Then the footer: open the app on the left; a mini Auto-send switch, Settings and Quit on the right. Auto-send and Microphone are the only dictation settings in the menu because they change with the task and the desk setup. The last dictation is not repeated in the menu: it is already on the clipboard. Model and shortcut belong only in Settings. Warnings and recovery actions expand the panel only when applicable. While recording, the Recording… label and a small Cancel Recording button share one row, the button trailing and vertically centred; other notices keep their own rows.

StatsWindowController owns the native unified compact toolbar: the centred tabs (Stats | Vocabulary | Settings, KhulumaSegments at its regular size in an NSToolbarItem fixed to its fitting size, with hover) and, on Stats only, trailing Usage information and Refresh as 13-point symbols in 28-by-24-point small native buttons. Only those two items come and go; the tabs are never rebuilt. The window title is hidden (it is still set for the Window menu) because a visible title takes the toolbar's leading space and NSToolbar then centres the tabs in what is left, right of the window's midpoint. Isolated preview runs add a short trailing secondary Preview label (help: Khuluma Preview · Sample Data) after the Stats items, so the preview stays distinct without moving the tabs. No content-level tabs or navigation header. While the window is open the app runs with the regular activation policy (Dock icon, Cmd-Tab, a minimal App/Edit/Window main menu from AppMainMenu.swift) and returns to accessory once it closes. The window starts at 560 by 712 points and can resize down to 560 by 420. Stats has four sections, top-aligned, split by faint full-width hairlines with 16 points either side: the lifetime figures (as in the menu, no caption: Total words, Time saved, Average WPM in three centered columns, with since <first date>, faster than typing and pauses left out beneath), Activity, four highlight columns (Current streak, Best day, Longest take, Longest streak), and recording time with word progress. Marks are Khuluma's own: an SF Symbol inside a 24-point ink ring, echoing the icon's eyes (flame, rosette, trophy, calendar, mic, checkered flag). Activity's header carries two Khuluma controls, not stock AppKit ones: Words per day is the shared hand-drawn switch (KhulumaSwitchStyle, as Auto-send in the menu: flame when on, ink track when off, stronger on hover) and 30 / 60 / 90 days is KhulumaSegments at its small size: a capsule track with a sliding soft-flame pill, hover and pressed surfaces, Left/Right arrows and an ember focus ring. Activity is the same height for every range and with Words per day on or off: the heatmap sits above a full-width 64-point chart, and without the chart its rows grow to take the chart's height. Cells are 20 points tall (taller without the chart), at most 1.3 times as wide as tall, and the heatmap is centred in the 520-point width. The line under the Activity header shows the range totals, or the hovered day in their place, in a fixed 18-point frame without scaling, so hovering never moves the layout; leaving a day clears it only if no other day is entered within 0.12 s. Content uses 20-point horizontal/12-point vertical insets; spare viewport height stays below the last box. Highlights carry symbols but no New badges or competitive framing. Recording time clearly separates all-time and today. Normal content fills the starting window without scrolling; its bounded ScrollView remains a fallback for short windows and additional notices. Settings has a 150-point custom sidebar (not NavigationSplitView: the title bar already holds the tabs) with four pages: General (Startup; Menu bar), Dictation (Recording: shortcut, microphone, sounds; Transcription: model, with the Scribe upload notice shown before it is chosen, language and API key; Delivery: auto-send, paste without sending), Cleanup (clean up, repetition, Manage Vocabulary link) and Advanced (diagnostic logging, Open Log, Open Config, Reload Settings). Sidebar rows are RingMark plus title, the selected row on a soft flame tint; rows take focus (ember outline) and Up/Down moves focus and page together. Pages are a rounded semibold 20-point title, small caps group labels and hairline-separated rows (title, optional secondary line, native control on the right), with no grouped-Form boxes; each page scrolls on its own and save, error and saving feedback sits in a footer outside the scroll view. SettingsModel.page holds the page in memory. Both destinations remain reachable in a short window.

## Elevation & Depth

StatusDropdownController hosts two SwiftUI views (figures and notices; footer) in their own NSMenuItems with the native Microphone item between them, and assigns its NSMenu to the status item, following the working Sys Stats implementation. Each hosted item is fitted from fittingSize before opening and with itemChanged while open. The dividers are SwiftUI Dividers inside the hosted views, so the old spacing and full-width lines stay; native separator items would add about 5 points each side and inset lines. The row's value ends at a right tab stop computed from a scratch menu's metrics, so the menu keeps its 400-point width; long names truncate. macOS owns the glass, corners, shadow, position and tracking. There is no pointer, custom gap, window positioning or mouse monitor. Click the icon to open, click it again or elsewhere to close, and Escape dismisses. Native placement takes priority over forced centering. The main window uses system chrome and grouped form surfaces.

## Shapes

Use system control shapes. Existing chart cells retain their small rounded corners and the existing 8-point notice radius. Use hairline native dividers for grouping.

## Components

### Foundational visual states

Use native disabled, focus, pressed, selected and hover states. Loading uses a system ProgressView or reserved en-dash metric values. Errors stay in context with an explanation and retry route; cached stats remain visible if refresh fails.

### Buttons and actions

Native titlebar toolbar items, icon-only menu footer controls and native form controls. Menu icons have a 28-by-24-point target, semantic hover and pressed surfaces, and native keyboard focus feedback. Opening the menu clears automatic initial button focus. The shortcut recorder is a compact key button; capture instructions appear while recording. Icon-only controls have accessible labels and help. Quit stays separate from opening the app. Recovery/discard actions retain their existing deliberate app flow.

### Navigation and data display

Stats is the home destination. Command-1, -2 and -3 select the tabs; Command-comma opens Settings; Escape returns to Stats from the other tabs. The menu gear opens the Settings tab and Manage Vocabulary in Settings opens the Vocabulary tab. Refresh and Command-R reload Stats. Usage information opens a compact transient native popover with coverage dates, privacy and the last update time, replacing the permanent footer. Refresh failures remain visible in the main content as well. Escape dismisses usage information first; otherwise Escape on Stats closes the window. Command-W closes either destination. StatusMenu and its isolated preview share the native menu container. StatsModel observes the ledger only while a surface is open; it has no polling loop. Menu updates and size invalidation use common run loop modes so they continue during menu tracking.

### Forms and overlays

SettingsModel owns authoritative config, save-in-progress and inline save/error feedback. CLIBridge writes through the CLI's validated settings command; the UI never writes TOML itself. Saves are immediate and reversible; disable dictation controls while saving or recording. The Appearance picker, the Paste without sending key and the Microphone picker (Dictation; the same options and stored device UID as the menu row, the way in when the menu bar item is hidden) stay available and store their app-only choices in the existing preferences domain. Native Picker owns its popup geometry, focus, keyboard selection and collision behavior. Each Settings page owns its row layout and scrolling. ShortcutRecorder owns physical key capture, Escape cancellation, Tab navigation and local event-monitor cleanup.

Choosing ElevenLabs is explicit, with an audio-upload and usage-credit notice visible before selection. Parakeet remains the default. Key availability is shown without exposing the credential. No automatic fallback uploads audio to another provider.

Dictation shows the ElevenLabs key row with either model selected, since Finder's Cloud action uses the same key. With Scribe selected, **Label sounds** is a native switch with an inline example. The Finder actions name the destination independently of dictation. Cloud asks for confirmation before uploading and names the recipient and credit use.

Cleanup & vocabulary is the Cleanup page of Settings: an immediate cleanup switch, a native repetition Picker and Manage Vocabulary. Vocabulary is a window tab and a standard Mac list editor. The window owns VocabularyModel, so a draft survives switching tabs until Save Changes or Revert; there is no Done/Cancel. VocabularyView has the rounded semibold 20-point Vocabulary title with a one-line description of the current section and a native search field on the right (Command-F), then a text tab strip (Fillers, Brands, Other words, Examples, each with its count; the selected one primary with a 2-point flame underline; one VoiceOver group, Left/Right move between sections), then an inset SwiftUI Table without alternating rows whose native headers are hidden in favour of small caps titles drawn to the table's equal column split: Filler; Heard as | Write as; or a narrow pass/fail column | Said | Expect. Columns are therefore not user-resizable. Cells edit in place: double-click or Return on a selected row, Tab to the next cell, Return to finish (or to move to a cell still empty), Escape to cancel. Finishing or cancelling returns keyboard focus to the table; while a row is open, Escape never switches the tab. Dictation pauses an open row with its text and resumes it, cursor at the end, when it finishes. Rows allow multiple selection. Under the table and attached to it, the classic +/− bar: + adds a row and starts editing it, − or Delete removes the selection, and an `ellipsis.circle` pull-down holds Undo (also Command-Z), Import…, Export… (Export Draft… when unsaved) and Revert to Saved…, plus New from Recent in Examples. The entry count sits small and secondary at the bar's trailing end. The bottom row has status on the left (warnings, Unsaved changes, Vocabulary saved., or Editing resumes when dictation finishes. while recording) and Revert and the prominent Save Changes (Command-S) on the right; Return stays with the table. VocabularyModel owns the draft, selection, the row being edited, validation feedback and Undo; KhulumaCore owns section rows and their edits; CLIBridge and the CLI own validated persistence. Nothing locks while typing: selecting another row or section, saving, importing or exporting puts a finished row into the draft (undoable) and drops an unfinished one; an invalid row stops them. Only an invalid row, such as a duplicate, stays open with a warning symbol (help gives the reason), the same message in the status and Save disabled until it is fixed or cancelled. In Examples a line under the table shows, for the selected or edited example, what the draft gives (with Use as Expected) or, for a failing one, the one-rule fix (Add Rule). No new color or typography tokens are introduced.

Import validates one JSON document (its panel states the 5,000-entry and 1 MB limits) and presents section totals plus added/changed/removed counts before replacing the draft. Save Changes commits the draft; saving with failing examples asks first (Save Anyway). Revert confirms before losing edits and otherwise rereads the saved file. Remove affects the draft and offers Undo. Saves retain an exact previous-file backup and reject a stale revision, keeping the draft available for export and retry. The first save retains the old text vocabulary intact and makes vocabulary.json the single active document. The isolated UI preview uses only in-memory vocabulary, sample examples (one failing) and sample recent dictations; sample actions never discover the daily CLI.

### Iconography

Interface controls use SF Symbols. The menu icon uses custom cursed-speech templates for Ready, Recording and Processing, with the existing SF Symbol for error. The idle glyph needs no textual Ready line. Gear and Back use standard Mac toolbar placement and accessible names.

The app icon uses the selected raised Inumaki-inspired direction: black enamel on ivory for light appearance, ivory enamel on charcoal for dark. The compact silhouette keeps a central mouth, two raised rings with solid pupils and short diagonal connections. Approved artwork and legacy production exports live in `assets/icons/app/`; `tools/make-khuluma-icons.swift` applies a shared raster crop and rounded mask. Legacy PNG/ICNS exports include the native canvas inset. `assets/icons/AppIcon.icon/Assets/` uses full-canvas derivatives so Icon Composer supplies that outer container once. Explicit default/dark raster specializations retain the approved raised materials; additional glass, specular, shadow and translucency effects are disabled.

The bundle stages the compiled `Assets.car` and declares `CFBundleIconName=AppIcon` for macOS 26+ appearance selection, alongside the ICNS fallback. `tools/compile-khuluma-icon.sh` and the icon-only workflow compile and verify the catalog with Xcode 26+. Build 347 verified the full-canvas artwork and Finder light/dark switching. Routine menu updates reuse that verified catalog. Icon style is Dark → Auto and general appearance remains Auto. Reproduction and artifact provenance live in `assets/icons/README.md` and `assets/icons/app/catalog-build.json`.

The native menu uses black-and-clear 28-by-20-point PDF canvases with artwork up to 18 points tall. StatusMenu caches both themes and owns the fixed 36-point slot, template tint and accessible status label. Ready keeps the approved brand glyph in both themes. Cursed speech uses a round, 14.5-point fanged mouth with voice strokes for Recording and two turning arcs around fang marks for Processing/Finishing. Full emblem keeps the side rings and changes the centre for those states. Errors retain the existing status symbol. macOS supplies light/dark/selected tint. Raised shading belongs only in the app icon.

Settings → Appearance → Menu bar icons switches immediately between Cursed speech (the default, set 1) and Full emblem (set 2), including during Recording or Processing. The choice persists across launches without changing CLI configuration. Both source sets remain in `assets/icons/menu-bar/concepts/`. Finishing is a visual name for the existing processing/delivery interval, including paste and optional send-key events. Phase timing, overlapping-take priority, labels and error handling stay unchanged.

### Motion

The Processing fang seal rotates slowly clockwise, one revolution every four seconds, as functional work-in-progress feedback. Cursed speech rotates the seal; Full emblem rotates only the central seal while its two side rings and connectors stay fixed. The native button and selected background stay still. A timer in common run loop modes keeps it moving while the native menu is open. Rotation uses elapsed monotonic time, so repeated Processing updates and theme switches do not restart it. Ready, Recording and Error remain static; leaving Processing stops its timer immediately. Reduce Motion keeps each theme's canonical seal still and reacts to preference changes. Existing Stats numeric transitions also respect Reduce Motion. The transient panel opens without animation; no decorative motion is added.

### Content and data visualization

Use words the person controls: model, shortcut, sounds, Start at Login, diagnostic logs. Both summaries use lifetime totals. Time saved shows a plain figure (no ≈; its help and usage information say it is an estimate) and retains signed values if dictation took longer than the typing estimate; help explains the configured typing speed and full delivery time, leaving out measured pauses longer than 1 second. Average WPM is words per minute while speaking: pauses longer than 1 second and the silence before and after speech (from the speech model's word timings) are left out; dictations from before Khuluma measured this still include their pauses. Recording time measures audio from delivered dictations, not estimated time saved. Records cover all stored daily history, independently of the selected Activity range; missing or partial daily coverage remains explicit. Missing values show a dash, never fabricated zero usage. Daily activity and streak remain separate from lifetime figures. The 8-point capsule milestone bar fills from zero to the next word target: 51,213 of 100,000 is 51.2%, matching 48,787 remaining. Keep a quiet inline acknowledgement when a newly reached target is observed. Existing Stats math and coverage explanations otherwise remain authoritative.

## Do's and Don'ts

- Do keep configuration details in Settings and the menu focused on glanceable usage.
- Do give the three lifetime figures priority, with activity, records and word progress underneath; use the native titlebar for secondary navigation.
- Do keep recovery actions reachable whenever a recording needs attention.
- Don't display routine readiness or local daemon internals as permanent menu rows.
- Don't treat a successful config write as evidence of a live cloud transcription.
