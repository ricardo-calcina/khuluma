# Khuluma icon artwork

Ricardo selected the raised Inumaki-inspired direction on 2026-10-23. These are matched light/dark **presentation previews**, generated with the built-in imagegen tool. The light image is the exact approved concept; the dark image changes the tile to charcoal and the raised symbol to ivory.

- [Light](app/raised-light-preview.png)
- [Dark](app/raised-dark-preview.png)
- [Menu bar preview and editable glyph](menu-bar/README.md)

The presentation PNGs retain their grey surround and cast shadow. The production exports strip that surround with a shared native crop/mask, retain the approved artwork, and provide clean alpha at every icon size. The repeatable exporter is tools/make-khuluma-icons.swift; export-preview.png shows both icons at small and large sizes on light/dark backgrounds. The approved presentation originals remain unchanged.

## Integration status

tools/build-khuluma-app.sh includes Khuluma.icns and the menu PDF before signing and declares CFBundleIconFile. The ICNS contains ordinary PNG-backed light representations plus the existing macOS nested dark representation, encoded as in the primary [icnsutil implementation](https://github.com/relikd/icnsutil/blob/main/icnsutil/IcnsFile.py). Standard light fallback decoding and iconutil export have been verified. Native system appearance selection still requires live verification; parser success does not establish automatic switching. Separate light/dark PNG and ICNS exports are retained. The current CLT-only environment lacks the Xcode asset compiler for Apple's newer Icon Composer pipeline. No runtime icon override or writes to the signed bundle are used.

Apple sources: [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [appearance settings](https://support.apple.com/guide/mac-help/change-appearance-settings-mchlp1225/mac), [temporary Dock override](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage). Icon & widget style has its own Auto setting; general appearance Auto alone does not guarantee icon switching.

The menu bar SVG/PDF is a separate black-and-clear template. The selected 18-point glyph uses a 28-by-20-point canvas in a stable 36-point status slot. StatusMenu preserves recording/processing/error feedback and native tinting.

## Final prompt set

### Approved light concept

Reference: Ricardo's second attached Inumaki symbol image. Generated using the built-in tool with an opaque background.

```text
Use case: logo-brand.
Asset type: preview concept for a macOS app icon, square image, one icon only.
Input image role: the attached image is the reference for the Inumaki cursed-speech emblem. Use ONLY its black symbol as inspiration, ignore all background lettering, crop artifacts, and colored marks.
Subject: keep its instantly recognisable compact silhouette: a dominant circular mouth at lower centre, two smaller circular rings raised at upper left and upper right, connected by short thick diagonal stems. Each side ring has a small solid circular pupil in its centre. Central mouth has opposing arcs of tapered fang marks pointing inward with a clear open gap in the middle. Symmetric, balanced, bold, clean.
Composition: large centred emblem inside a macOS-style rounded-square tile, occupying about 74% of tile width with comfortable padding. Tile on a plain neutral light-grey canvas, straight-on view, no perspective. Same geometry in all concepts: central circle about 1.65 times diameter of a side ring; side rings close to the mouth; 6 tapered fangs on upper inner arc and 6 on lower inner arc. Preserve a clear white/open centre. Top rings connected at approximately 10 and 2 o'clock on the central circle.
Constraints: visually sharp professional app-icon concept. No microphone, speech bubble, waveform, letters, app name, numbers, labels, character portrait, scene, hands, extra symbols, watermarks or surrounding UI. Preserve a mouth, not a clock, gear or sunburst. Nothing touches tile edges.
Treatment: restrained tactile macOS icon. Warm ivory rounded-square tile with subtle curved edge and gentle studio light. Identical pure-black symbol appears made from a thin raised matte-black enamel inlay, with a very shallow bevel and tiny contact shadow. White mouths and rings remain open and clean; black pupils and black tapered fangs stay sharp. Avoid metallic chrome and heavy 3D depth. Quiet premium finish; no extra decoration.
```

### Matching dark presentation

Reference: the approved light concept above. Generated using the built-in tool with an opaque background.

```text
Use case: precise-object-edit.
Edit target: the attached approved Khuluma raised LIGHT app icon.
Create its matching DARK appearance by changing ONLY materials/colours on the tile and symbol. Deep charcoal ceramic rounded-square tile, raised warm ivory enamel symbol. Preserve the exact original composition, tile size, tile corner geometry, central mouth and all fang shapes, two raised rings and pupils, connecting stems, shallow bevels, contact shadows, and top-left lighting.
Preserve the exact neutral light-grey exterior presentation backdrop and soft external drop shadow. This is an OPAQUE presentation render, no transparency, no background removal. Keep every edge smooth and clean. One icon only, same square framing as the original. No words, no labels, no extra symbols. Ivory rings/pupils/fangs are raised with dark open interiors; charcoal tile subtly lit so it retains depth. The same approved tactile appearance in a dark palette.
```

