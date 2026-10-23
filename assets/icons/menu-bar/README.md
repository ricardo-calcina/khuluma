# Menu bar glyph

Ricardo selected the 18-point Ready glyph and cursed-speech status set 1 on 2026-10-23. The app bundler copies three vector PDFs to Resources, and StatusMenu caches them as native template images. Ready keeps the approved emblem, Recording uses the speaking mouth, and Processing/Finishing uses the turning fang seal. Errors retain the existing SF Symbol. A fixed 36-point status-item slot fits the artwork and keeps neighbouring items still.

The template is black and clear only: macOS supplies the tint for light, dark and selected states. Four bold fang marks on each arc preserve the mouth at menu bar size. The app icon's raised finish is reserved for the larger app icon.

The [cursed speech comparison](concepts/README.md) preserves both sets. Set 1 is selected for production; set 2's full-emblem vectors remain available for a possible future theme setting. No theme control or animation is added in this change.

- `khuluma-menu-template.pdf`: vector template on a 28 × 20 pt canvas, with an 18 pt glyph.
- `khuluma-recording-template.pdf`: approved set 1 speaking mouth, bundled as `KhulumaRecordingTemplate.pdf`.
- `khuluma-finishing-template.pdf`: approved set 1 turning fang seal, bundled as `KhulumaFinishingTemplate.pdf`.
- `khuluma-menu-template.svg`: matching editable vector.
- `khuluma-menu-template.png` / `khuluma-menu-template@2x.png`: transparent 28 × 20 / 56 × 40 px exports.
- `menu-bar-preview.png`: illustrated 24 pt menu bars at 2× Retina resolution, comparing 16 pt and 18 pt glyph heights in light, dark and selected states; enlarged detail below. The simulated selected background is a preview, not a capture of the installed app.

Rerun the renderer from this folder with `swift render.swift`. It only writes the preview assets beside itself. No app build or running status item is involved.

The Recording and Finishing production PDFs are exact copies of `concepts/speaking.pdf` and `concepts/sealing.pdf`. `concepts/render.swift` reproduces those drawings and the retained set 2 assets. After rendering, promote the selected PDFs with `cp concepts/speaking.pdf khuluma-recording-template.pdf` and `cp concepts/sealing.pdf khuluma-finishing-template.pdf` from this folder. The existing Ready renderer and PDF stay unchanged.

Finishing maps to the existing Processing phase through transcription, paste and optional send-key events. A newer take can start while an earlier one processes. This change replaces artwork only; it does not alter delivery, phase priority, accessibility labels or error handling.
