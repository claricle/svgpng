# Reproducing and updating goldens

The corpus at `spec/fixtures/svg_to_png/manifest.json` pins SVG inputs, explicit
font bytes, PNG bytes, public metadata, typed failures, and encoder settings.
`bundle exec rake svgpng:verify_manifest` checks the committed checksums without
loading a native renderer. Native golden specs use the explicitly supplied
`SVGPNG_TEST_NATIVE_LIBRARY`; see the native build instructions in
[`svg-to-png.md`](decisions/svg-to-png.md).

The committed corpus includes width-only and height-only sizing, two-axis
containment, exact decimal scale, and a positive 32768-by-1 canvas boundary. Font
cases use supplied regular, bold, italic, and condensed faces, caller-ordered
fallback families, whole-cluster fallback, and first-use warning order with
deduplication. Native font integration also compares style and stretch selection
against exact-face controls in both supplied-face orders. These local acceptance
checks do not establish the pending seven-target byte-identity gate.

Golden changes are intentional compatibility changes. Review the renderer,
encoder, dependency, version and CHANGELOG impact before regeneration. Build the
native artifact from the source pinned in `vendor/manifest.yml`, finish that build,
and keep the artifact unchanged while the task runs. Use an absolute artifact
path. Do not regenerate with a downloaded or unrelated renderer merely to make a
comparison pass.

From the repository root, after building the artifact, run:

```sh
SVGPNG_COMPATIBILITY_UPDATE=yes \
SVGPNG_COMPATIBILITY_IMPACT='Reviewed: describe the version and CHANGELOG decision here' \
SVGPNG_TEST_NATIVE_LIBRARY=/absolute/path/to/svgpng.dylib \
SVGPNG_GOLDEN_BUILD_COMMAND='Record the exact command and build environment used' \
SVGPNG_GOLDEN_TOOLCHAIN='Record actual rustc -Vv and C compiler --version output' \
bundle exec rake svgpng:update_goldens
```

Replace each descriptive value with the reviewed decision and actual build
information; the task rejects missing or blank values. The artifact extension is
platform dependent. The build-command and toolchain values are operator supplied
attestations; hashing the artifact does not prove that it was built from the
recorded source. Preserve the corresponding build log as review evidence.

The task first verifies existing input/output checksums and encoding settings. For
an intentional SVG or font change, review and update its input checksum in the
manifest before running the task. Keep old PNG checksums until regeneration.
The task prints old and new renderer identifiers and PNG digests, renders every
entry before writing outputs, and rejects changed error classes. Error details
and successful metadata are updated for review. If rendering fails or the
artifact checksum changes during rendering, it writes no golden files. File
writes themselves are not a filesystem transaction; restore from version control
if a write fails.

The new `renderer` record replaces the old record using the current vendor
manifest: upstream/fork commits, patch hashes, renderer source and Cargo lock
hashes, and all three source archive identities. It also records the SHA256 and
size of the actual library used, reviewed compatibility impact, explicit build
command/toolchain information, declared vendor build settings, and running Ruby
and platform. Declared vendor settings and actual toolchain evidence are distinct.
A source update therefore updates the golden renderer identity even if PNG bytes
are unchanged. Keep vendor provenance current before regenerating.

After regeneration, inspect the PNGs and review every manifest change, including
warnings, font selection, dimensions and failure details. Run the manifest check
again and the native golden specs against the same artifact:

```sh
bundle exec rake svgpng:verify_manifest
SVGPNG_TEST_NATIVE_LIBRARY=/absolute/path/to/svgpng.dylib \
bundle exec rspec spec/svgpng/golden_spec.rb
```

Commit intended input, output and provenance changes together. Do not accept
unexplained byte drift. Fixture origins and font licensing are documented in the
[corpus README](../spec/fixtures/svg_to_png/README.md); dependency licenses are
recorded under `vendor/licenses` and `vendor/rust-dependencies.json`.
