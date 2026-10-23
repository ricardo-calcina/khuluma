# Menu bar glyph

Ricardo selected the 18-point glyph on 2026-10-23. The app bundler copies its PDF to Resources/KhulumaMenuTemplate.pdf, and StatusMenu uses it while ready. Recording, processing and errors retain their existing status symbols. A fixed 36-point status-item slot fits the artwork and keeps neighbouring items still.

The template is black and clear only: macOS supplies the tint for light, dark and selected states. Four bold fang marks on each arc preserve the mouth at menu bar size. The app icon's raised finish is reserved for the larger app icon.

Two [cursed speech status concepts](concepts/README.md) compare custom Recording and Finishing glyphs while keeping this Ready template unchanged. They are previews awaiting a choice; the installed app continues to use its current status symbols.

- `khuluma-menu-template.pdf`: vector template on a 28 × 20 pt canvas, with an 18 pt glyph.
- `khuluma-menu-template.svg`: matching editable vector.
- `khuluma-menu-template.png` / `khuluma-menu-template@2x.png`: transparent 28 × 20 / 56 × 40 px exports.
- `menu-bar-preview.png`: illustrated 24 pt menu bars at 2× Retina resolution, comparing 16 pt and 18 pt glyph heights in light, dark and selected states; enlarged detail below. The simulated selected background is a preview, not a capture of the installed app.

Rerun the renderer from this folder with `swift render.swift`. It only writes the preview assets beside itself. No app build or running status item is involved.
