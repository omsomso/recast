# libogg and libvorbis 1.3.7 (vendored)

- Source: the copy bundled with JUCE in VSTS (`third_party/JUCE/modules/juce_audio_formats/codecs/oggvorbis`,
  JUCE commit `91ad83ae34a81e0833b1a2b0866f54846370ae53`), copied unmodified on 6 November 2026.
- JUCE's few changes to the Xiph sources are marked "JUCE CHANGE STARTS HERE" (see `Ogg Vorbis Licence.txt`);
  they only silence warnings and fix a type. `JUCE_CDECL` is defined empty by `Package.swift`.
- Licence: Xiph.Org BSD-style (`libvorbis-1.3.7/COPYING`, `Ogg Vorbis Licence.txt`).
- Built as the `COggVorbis` C target from `oggvorbis_unity.c`, one translation unit including the same files in the
  same order as JUCE (JUCE removed a few duplicate static helpers, so the files do not build separately).
- Recast uses it to write Ogg Vorbis files and to mux Opus packets into Ogg pages.
