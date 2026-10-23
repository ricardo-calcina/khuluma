# Cursed speech status concepts

Ricardo selected set 1 for production on 2026-10-23, then requested a circular Recording mouth and both sets in Settings. They are now Cursed speech and Full emblem in Settings → Appearance → Menu bar icons. These source drawings remain together for comparison. Ready reads the existing approved `../khuluma-menu-template.pdf` unchanged. The other glyphs are original vectors inspired by the same mouth-and-fangs vocabulary.

[Compare the two sets](status-options.png). The sheet includes the rounder set 1 Recording mouth. The large drawings show the shapes; the light/dark strips below each set render the 28 × 20 pt canvas at its intended size, with artwork up to 18 pt tall and 2× Retina output. These are static illustrated strips, not installed menu bar captures. The runtime slowly rotates the set 1 seal or set 2 centre during Processing.

| State | Set 1: speaking mouth and turning seal | Set 2: keep the full emblem |
| --- | --- | --- |
| Ready | Existing approved emblem | Existing approved emblem |
| Recording | Fanged open mouth with outward voice strokes | Full emblem with a dark mouth and clear fangs |
| Finishing | Two turning arcs around fang marks | Full emblem with the turning seal in its centre |

Finishing is an in-progress state, returning to Ready after the existing processing/delivery flow settles. The selected set replaces the waveform with the fang seal and the microphone with the speaking mouth. It adds no success tick or separate permanent Done state. The app icon, Ready glyph and error symbol remain as approved.

The existing code keeps Processing active until `TakePipeline` finishes transcription/cleanup and `Deliverer` completes its synchronous paste/send event sequence; `AppController` then calls `processingFinished`. It does not wait for the destination app to acknowledge the posted events. A newer recording can start while an earlier take processes, so Finishing does not mean the app is unavailable. These previews change no state logic.

Set 1 gives the three states more distinct silhouettes. Set 2 keeps stronger continuity with the current emblem, at the cost of more detail in the small centre. Production PDFs are copied from these drawings for bundling. `emblem-frame.pdf` and `emblem-rotor.pdf` split the finishing emblem so only the central seal rotates; together they reproduce the complete `emblem-sealing.pdf` without redrawing its side rings.

`render.swift --production` regenerates the revised mouth and split layers, transparent 1×/2× PNGs and comparison sheet, then copies five production PDFs. It preserves the approved Ready, set 1 finishing and full-emblem reference PDFs. Omitting `--production` redraws all concept sources, including the retained references. The script only reads/writes these icon assets:

```sh
xcrun swift -module-cache-path /private/tmp/khuluma-icon-swift-cache assets/icons/menu-bar/concepts/render.swift --production
```

No app build, installation, microphone capture, model warm-up or runtime restart is needed.
