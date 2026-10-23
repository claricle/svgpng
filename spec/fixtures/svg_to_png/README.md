# SVG to PNG acceptance corpus

The SVG documents in this directory are small repository-authored test inputs.
They exercise geometry, transparency, effects, references, sizing, explicit fonts,
fallback, static rendering and typed rejection paths. They are not copied image
artworks. Some manifest entries reuse an SVG with a different render profile.
The PNG files are generated outputs of the pinned renderer and encoder for those
inputs. `manifest.json` records input/output SHA256 checksums, profile options,
expected metadata or errors, font checksums and renderer provenance.

This README documents origin; it does not grant a separate license or replace the
project's applicable license terms. Generated PNGs are acceptance artifacts from
these authored inputs, not independent third-party image fixtures.

Text fixtures use only the supplied Noto font files in
`native/svgpng_renderer/tests/fonts`, copied from the verified resvg v0.48.1
release archive's `crates/resvg/tests/fonts` directory. Those fonts retain their
SIL Open Font License 1.1 terms and copyright notices. See
`vendor/licenses/fonts/OFL-1.1.txt`, `vendor/licenses/fonts/COPYRIGHT.txt`, and
`vendor/manifest.yml` for exact files, checksums and archive provenance. Project
licensing does not replace the font licenses. No system font is a corpus input.

Run `bundle exec rake svgpng:verify_manifest` for checksum verification without
native rendering. Regenerate only after reviewing compatibility impact, using
the explicit command and provenance requirements in
[`docs/goldens.md`](../../../docs/goldens.md). Review changed PNGs, public metadata
and typed error details together with their renderer identifiers.
