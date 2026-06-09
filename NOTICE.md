# Notices

flutter_fbdev is licensed under the MIT License (see [LICENSE](LICENSE)).

## Third-party

- `native/flutter_embedder.h` is the public Flutter Engine embedder API header,
  copyright The Flutter Authors, licensed under the BSD 3-Clause License. It is
  vendored unmodified so the embedder can be built against the engine ABI without
  a full engine checkout. See https://github.com/flutter/engine for the source and
  its license.
- `native/stb_vorbis.c` is Sean Barrett's public-domain Ogg Vorbis decoder,
  vendored unmodified and compiled into the embedder to decode bundled audio for
  ALSA playback. See https://github.com/nothings/stb for the source.

The embedder links against `libflutter_engine.so`, which is produced by
`flutterpi_tool` / the Flutter engine and ships in your app bundle; it is not part
of this repository.

## Example assets

- The example app's background music is "blank page" by 4mat, bundled as
  `example/assets/audio/blank_page.ogg`. All rights remain with the artist; it is
  included only to make the demo feel alive.
