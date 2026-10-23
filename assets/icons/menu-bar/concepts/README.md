# Cursed speech status concepts

Preview only: these resources are not bundled into the app. Ready reads the existing approved `../khuluma-menu-template.pdf` unchanged. The other four glyphs are original vector concepts inspired by the same mouth-and-fangs vocabulary.

[Compare the two sets](status-options.png). The large drawings show the shapes; the light/dark strips below each set render the 28 × 20 pt canvas at its intended size, with artwork up to 18 pt tall and 2× Retina output. These are illustrated strips, not installed menu bar captures. No animation is shown or implemented.

| State | Set 1: speaking mouth and turning seal | Set 2: keep the full emblem |
| --- | --- | --- |
| Ready | Existing approved emblem | Existing approved emblem |
| Recording | Fanged open mouth with outward voice strokes | Full emblem with a dark mouth and clear fangs |
| Finishing | Two turning arcs around fang marks | Full emblem with the turning seal in its centre |

Finishing is an in-progress state, returning to Ready after the existing processing/delivery flow settles. It replaces the current waveform in the proposed design; it is not a success tick or a separate permanent Done state. Recording replaces the current microphone. The app icon and Ready glyph remain as approved. Error handling and installed symbols are outside this preview.

The existing code keeps Processing active until `TakePipeline` finishes transcription/cleanup and `Deliverer` completes its synchronous paste/send event sequence; `AppController` then calls `processingFinished`. It does not wait for the destination app to acknowledge the posted events. A newer recording can start while an earlier take processes, so Finishing does not mean the app is unavailable. These previews change no state logic.

Set 1 gives the three states more distinct silhouettes. Set 2 keeps stronger continuity with the current emblem, at the cost of more detail in the small centre. No set has been selected for implementation.

`render.swift` draws four vector PDFs, transparent 1×/2× PNGs and the comparison sheet. It only reads/writes these icon assets:

```sh
swift -module-cache-path /private/tmp/khuluma-concept-module-cache assets/icons/menu-bar/concepts/render.swift
```

No app build, installation, microphone capture, model warm-up or runtime restart is needed.
