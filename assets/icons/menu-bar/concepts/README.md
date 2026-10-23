# Cursed speech status concepts

Ricardo selected set 1 for production on 2026-10-23 and asked to retain set 2 for a possible future Settings theme. These source drawings remain together for comparison. Ready reads the existing approved `../khuluma-menu-template.pdf` unchanged. The other four glyphs are original vectors inspired by the same mouth-and-fangs vocabulary.

[Compare the two sets](status-options.png). This sheet records the preview before selection and installation. The large drawings show the shapes; the light/dark strips below each set render the 28 × 20 pt canvas at its intended size, with artwork up to 18 pt tall and 2× Retina output. These are illustrated strips, not installed menu bar captures. No animation is shown or implemented.

| State | Set 1: speaking mouth and turning seal | Set 2: keep the full emblem |
| --- | --- | --- |
| Ready | Existing approved emblem | Existing approved emblem |
| Recording | Fanged open mouth with outward voice strokes | Full emblem with a dark mouth and clear fangs |
| Finishing | Two turning arcs around fang marks | Full emblem with the turning seal in its centre |

Finishing is an in-progress state, returning to Ready after the existing processing/delivery flow settles. The selected set replaces the waveform with the fang seal and the microphone with the speaking mouth. It adds no success tick or separate permanent Done state. The app icon, Ready glyph and error symbol remain as approved.

The existing code keeps Processing active until `TakePipeline` finishes transcription/cleanup and `Deliverer` completes its synchronous paste/send event sequence; `AppController` then calls `processingFinished`. It does not wait for the destination app to acknowledge the posted events. A newer recording can start while an earlier take processes, so Finishing does not mean the app is unavailable. These previews change no state logic.

Set 1 gives the three states more distinct silhouettes. Set 2 keeps stronger continuity with the current emblem, at the cost of more detail in the small centre. The set 1 PDFs are promoted unchanged to `../khuluma-recording-template.pdf` and `../khuluma-finishing-template.pdf` for bundling. Set 2's `emblem-speaking.pdf` and `emblem-sealing.pdf`, PNGs and renderer are retained; the theme setting is future work.

`render.swift` draws four vector PDFs, transparent 1×/2× PNGs and the comparison sheet. It only reads/writes these icon assets:

```sh
swift -module-cache-path /private/tmp/khuluma-concept-module-cache assets/icons/menu-bar/concepts/render.swift
```

No app build, installation, microphone capture, model warm-up or runtime restart is needed.
