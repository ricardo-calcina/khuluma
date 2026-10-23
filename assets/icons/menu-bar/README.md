# Menu bar glyph

Ricardo selected the 18-point Ready glyph and cursed-speech status set 1 on 2026-10-23, then requested a rounder Recording mouth and a theme picker. Settings → Appearance → Menu bar icons now switches between Cursed speech and Full emblem. The choice applies immediately and persists across launches. Ready keeps the approved emblem in both themes; errors retain the existing SF Symbol. A fixed 36-point status-item slot fits the artwork and keeps neighbouring items still.

The template is black and clear only: macOS supplies the tint for light, dark and selected states. Four bold fang marks on each arc preserve the mouth at menu bar size. The app icon's raised finish is reserved for the larger app icon.

The [cursed speech comparison](concepts/README.md) preserves both sets and the renderer. Cursed speech is the default: a circular 14.5-point speaking mouth with voice strokes for Recording and a turning fang seal for Processing. Full emblem keeps the side rings in both states and changes the centre.

- `khuluma-menu-template.pdf`: vector template on a 28 × 20 pt canvas, with an 18 pt glyph.
- `khuluma-recording-template.pdf`: approved set 1 speaking mouth, bundled as `KhulumaRecordingTemplate.pdf`.
- `khuluma-finishing-template.pdf`: approved set 1 turning fang seal, bundled as `KhulumaFinishingTemplate.pdf`.
- `khuluma-emblem-recording-template.pdf`: set 2 speaking emblem, bundled as `KhulumaEmblemRecordingTemplate.pdf`.
- `khuluma-emblem-finishing-template.pdf`: complete static set 2 seal for Reduce Motion, bundled as `KhulumaEmblemFinishingTemplate.pdf`.
- `khuluma-emblem-frame-template.pdf`: fixed set 2 side rings/connectors, bundled as `KhulumaEmblemFrameTemplate.pdf`.
- `khuluma-emblem-rotor-template.pdf`: set 2 central seal, bundled as `KhulumaEmblemRotorTemplate.pdf`.
- `khuluma-menu-template.svg`: matching editable vector.
- `khuluma-menu-template.png` / `khuluma-menu-template@2x.png`: transparent 28 × 20 / 56 × 40 px exports.
- `menu-bar-preview.png`: illustrated 24 pt menu bars at 2× Retina resolution, comparing 16 pt and 18 pt glyph heights in light, dark and selected states; enlarged detail below. The simulated selected background is a preview, not a capture of the installed app.

Rerun the renderer from this folder with `swift render.swift`. It only writes the preview assets beside itself. No app build or running status item is involved.

Production PDFs are exact copies of their counterparts in `concepts/`. From the repository root, `xcrun swift -module-cache-path /private/tmp/khuluma-icon-swift-cache assets/icons/menu-bar/concepts/render.swift --production` regenerates the circular Recording mouth, split emblem layers and comparison PNG, then promotes five production PDFs. It preserves the approved Ready, set 1 Finishing and full-emblem reference PDFs. The fixed frame plus unrotated centre composites exactly to the complete static full-emblem seal. Its rotation centre is (14, 7.582984) in the native nonflipped 28 × 20 pt canvas; the 6.9657133 pt rotor radius fits at every angle.

Finishing maps to the existing Processing phase through transcription, paste and optional send-key events. The seal rotates clockwise once every four seconds while that phase is visible. Full emblem rotates only the centre, keeping the two side rings and connectors stationary. StatusMenu caches 96 black-and-clear template frames per theme and updates only the button image using a common-mode timer, including while the menu tracks. Repeated Processing updates and theme switches preserve the rotation's start time. Ready, Recording, Error and Reduce Motion use static images; the motion timer stops when it is no longer needed. A newer take can start while an earlier one processes. Delivery, phase priority, accessibility labels and error handling are unchanged.
