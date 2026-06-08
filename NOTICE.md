# Notices

flutter_fbdev is licensed under the MIT License (see [LICENSE](LICENSE)).

## Third-party

- `native/flutter_embedder.h` is the public Flutter Engine embedder API header,
  copyright The Flutter Authors, licensed under the BSD 3-Clause License. It is
  vendored unmodified so the embedder can be built against the engine ABI without
  a full engine checkout. See https://github.com/flutter/engine for the source and
  its license.

The embedder links against `libflutter_engine.so`, which is produced by
`flutterpi_tool` / the Flutter engine and ships in your app bundle; it is not part
of this repository.
