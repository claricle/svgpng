# Test fonts

The four non-condensed font files and Noto-LICENSE-OFL.txt are copied unchanged from
`crates/resvg/tests/fonts` in the verified resvg v0.48.1 release archive.
The archive SHA-256 is
`13ed5a2bae7a01156288ecae5bf944cf7d1c572742c19fc68027947a4d87294c`.
The fonts are licensed under the included SIL Open Font License 1.1.

They exercise actual supplied-font shaping, requested weight and italic style,
complete Devanagari cluster fallback, missing glyph diagnostics, and per-call
concurrency isolation.
They are test fixtures and are never searched or loaded by the production API.

`NotoSans-Italic.ttf` is copied unchanged from the same archive path
`crates/resvg/tests/fonts/NotoSans-Italic.ttf` and uses the included
`Noto-LICENSE-OFL.txt`. Its SHA-256 is
`35600501daadd3e9030ee6ed8098fd3c7f31bfd898ca58da8edf793a3231c48b`,
also recorded in the golden manifest.

`NotoSans-Condensed.ttf` is copied unchanged from the official notofonts/noto-fonts
repository at commit `ffebf8c1ee449e544955a7e813c54f9b73848eac`, path
`hinted/ttf/NotoSans/NotoSans-Condensed.ttf`. Its SHA-256 is
`5c15b8bb0ac1bbd533917b23968c6f0a420f143533e1293cc575f4f9dd543be8`.
The same commit's root `LICENSE` is retained unchanged as
`NotoSans-Condensed-LICENSE-OFL.txt`, SHA-256
`0dab92d0544f7b233403f14b84a663bdbfa746982eda629e7f4f9ffe1b036feb`.
This SIL Open Font License 1.1 fixture tests real parsed condensed face metadata
against the supplied normal-width face, including fallback selection.
