# Test fonts

These four font files and Noto-LICENSE-OFL.txt are copied unchanged from
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
