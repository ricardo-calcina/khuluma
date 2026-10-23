# Khuluma icon artwork

Ricardo selected the raised Inumaki-inspired direction on 2026-10-23. These are matched light/dark **presentation previews**, generated with the built-in imagegen tool. The light image is the exact approved concept; the dark image changes the tile to charcoal and the raised symbol to ivory.

- [Light](app/raised-light-preview.png)
- [Dark](app/raised-dark-preview.png)
- [Menu bar preview and editable glyph](menu-bar/README.md)

The presentation PNGs retain their grey surround and cast shadow. The production exports strip that surround with a shared native crop/mask and retain the approved artwork. The repeatable exporter is `tools/make-khuluma-icons.swift`; `app/export-preview.png` shows the legacy PNG/ICNS exports at small and large sizes on light/dark backgrounds. The approved presentation originals remain unchanged.

The exporter produces two canvas treatments from the same raster crop and rounded mask. Legacy PNG/ICNS exports place an 824-pixel tile on a 1024-pixel canvas, with a 100-pixel inset. The native layers in `AppIcon.icon/Assets/` draw the tile across the full 1024-pixel canvas because Icon Composer supplies the outer container. Copying the legacy PNGs into the native source adds a second inset and makes the artwork too small.

## Integration status

`tools/build-khuluma-app.sh` stages `Assets.car`, `Khuluma.icns` and the three status PDFs before signing, and declares `CFBundleIconName=AppIcon` alongside `CFBundleIconFile=Khuluma.icns`. The native catalog supplies macOS 26+ appearance selection; the ICNS remains the older-system fallback. The ICNS contains ordinary PNG-backed light representations plus a nested dark representation, encoded as in the primary [icnsutil implementation](https://github.com/relikd/icnsutil/blob/main/icnsutil/IcnsFile.py). Separate light/dark PNG and ICNS exports are retained. No runtime icon override or writes to the signed bundle are used.

The native source is `AppIcon.icon`, with explicit default/dark raster specializations and added glass, specular, shadow and translucency effects disabled. Its schema follows primary [OpenSC2K](https://github.com/OpenSC2K/OpenSC2K/blob/7b38850dc0520279f60023e7ad41fc461c118f0a/game/assets/icons/OpenSC2K.icon/icon.json) and [AssetCatalogTinkerer](https://github.com/insidegui/AssetCatalogTinkerer/blob/f5208620695b1eec451d6943beeb4ac1bfd37c63/Resources/AppIconV5.icon/icon.json) examples; only Khuluma's approved artwork is included.

`tools/compile-khuluma-icon.sh --out NEW_DIRECTORY` requires full Xcode 26+, validates the declared 1024-pixel layers, compiles only the catalog, then requires a nonempty `Assets.car` and `CFBundleIconName=AppIcon` in `partial-info.plist`. Run it from the repository root with a fresh output path. The current CLT-only Mac cannot compile `.icon` sources. The icon-only GitHub workflow compiles on `macos-latest` when the temporary `build/icon-catalog` branch is pushed and uploads the catalog and partial plist. The catalog's source commit, workflow run, Xcode version and checksum are recorded in `app/catalog-build.json`.

Build 351 is installed locally from `6bc646c`, with selected cursed-speech status set 1. Its full-canvas app catalog is unchanged from build 347, compiled with Xcode 26.6 from `6f5bf52` in the successful [icon-only build](https://github.com/ricardo-nth/khuluma/actions/runs/40003374382). Native Finder Get Info verified build 347's light/dark artwork with a single clean tile and automatic switching. Icon style remains Dark → Auto and general appearance Auto. The temporary public build branch was removed after preserving the compiled catalog and provenance locally. All five icon resources in build 351 match source; the Ready PDF and app catalog also match the previous installed bundle. The signed build 347 is retained at `/Users/admin/Applications/.khuluma-app.atWD6N/previous.app`; older recovery material is recorded in LOG.

Apple sources: [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [appearance settings](https://support.apple.com/guide/mac-help/change-appearance-settings-mchlp1225/mac), [temporary Dock override](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage). Icon & widget style has its own Auto setting; general appearance Auto alone does not guarantee icon switching.

The menu bar artwork uses separate black-and-clear templates on 28-by-20-point canvases, with artwork up to 18 points tall in a stable 36-point status slot. Ready keeps the emblem, Recording uses the speaking mouth, and Processing/Finishing uses the fang seal. StatusMenu caches those PDFs and preserves native tinting, accessibility labels, phase timing and error feedback. Set 2's full-emblem alternatives remain in [the comparison source](menu-bar/concepts/README.md) for a possible future theme setting.

Current acceptance evidence lives at `/private/tmp/khuluma-status-qa.suYfJ3/`: 36 packaging regressions, strict signature verification and doctor pass; configuration/daemon hashes and daemon PID are unchanged. A private clone of the installed build produced 16 real NSStatusBarButton captures with 0 failures. All three custom resources loaded; the 36-point slot, 28-by-20-point custom image sizes and owning window remain fixed. Light/dark images were visually inspected; eight menu-open captures and dismissals completed using common run loop modes. Cached button captures do not include the native selected background material, so that background is not visually verified. Earlier app-icon evidence remains at `/private/tmp/khuluma-icons-qa.bhadKs/`. The isolated preview-only option `-KhulumaPreviewIconSnapshots DIRECTORY` repeats this check with all three required private runtime overrides. It does not start microphone capture, CLI requests or a daemon. The daily app has no preview overrides.

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

