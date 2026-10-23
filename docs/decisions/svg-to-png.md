# SVG-to-PNG rendering contract

**Status: contract accepted for implementation; native delivery gates pending.** This decision fixes the public behavior and proposed ownership for the renderer. The current repository supplies a Ruby shell, exact profile resolution, standalone input guards, checked C RGBA conversion, a pinned-dependency PNG encoder source, an owned Fiddle binding, and staged release/package-resolution checks. No complete native shim, resvg fork, platform package, golden corpus, native render, or cross-platform byte-identity result is present. Proposed components below remain requirements until backed by implementation evidence.

## Public Ruby boundary

The public call is:

```ruby
Svgpng.render(svg_bytes, profile: {}, fonts: {}, fallback_fonts: [])
```

`svg_bytes` is a byte string containing one SVG document. `profile` is a hash
with only symbol keys `:width`, `:height`, `:scale`, and `:background`.
`fonts` maps a requested CSS family spelling to one or more `Svgpng::FontFace`
objects. `fallback_fonts` is an ordered array of those faces. A face is
constructed as `Svgpng::FontFace.new(bytes:, source_id:)`; its bytes are
immutable after construction and `source_id` is caller-provided diagnostic
text. Family names, style, weight, stretch, and glyph coverage are derived from
OpenType metadata in the bytes. Caller declarations cannot override metadata.
There is no resource map, base path, directory, filesystem loader, network
loader, or other external-resource injection API.

Successful rendering returns `Svgpng::Result` with `png_bytes`, integer
`width` and `height`, ordered structured `warnings`, and a `font_manifest`
diagnostic describing resolved faces and their source IDs and content digests.
The manifest never exposes native pointers or engine-specific objects. Digests
are computed from supplied bytes at runtime; no native-source digest is asserted
by this decision.

The stable public error classes are `ProfileError`, `InputError`, `FontError`,
`FontMetadataError`, `DuplicateFontError`, `MissingFamilyError`,
`MissingGlyphError`, `ForbiddenReferenceError`, `LimitError`, `NativeError`,
`EncodingError`, and `UnsupportedPlatformError`, all under `Svgpng`. They
represent observable input, policy, native-boundary, and encoding failures.
Errors must not include sensitive host paths or resource contents. Invalid
profile values use `ProfileError`; malformed SVG or URI syntax uses
`InputError`; invalid OpenType bytes use `FontMetadataError`; duplicate
normalized faces use `DuplicateFontError`; absent requested families use
`MissingFamilyError`; uncovered shaped clusters use `MissingGlyphError`;
prohibited references use `ForbiddenReferenceError`; preflight/pre-allocation
bounds use `LimitError`; native status failures use `NativeError`; PNG writer
failures use `EncodingError`. A shell install can be required and its non-render
API inspected on any platform; only a render call without a matching native
package raises `UnsupportedPlatformError`, including detected and supported
platform identifiers.

## Profile validation and output geometry

The implementation accepts only the four profile keys above. Unknown keys and
string keys are errors. `width` and `height`, when present, must be positive
Ruby integers (booleans are not integers for this contract), within 32768.
`scale` must be a positive, finite base-10 decimal string. Parse it as an exact
rational; reject numeric Ruby values, NaN, infinity, zero, negatives, and
malformed strings. `background` must be a string. `scale` cannot be combined
with either dimension. After deriving and rounding dimensions, enforce each
dimension <= 32768 and total pixels <= 64,000,000.

Resolve the SVG's intrinsic viewport in the pinned parser. CSS px is one source
unit; physical CSS lengths convert at 96 dpi. Resolve percentage root width or
height against a 300 by 150 default viewport. Reject other relative root sizing,
including `em`, `rem`, `ex`, and `calc()`, so the result cannot depend on font
or host state. Reject non-positive or non-finite resolved dimensions.

Intrinsic-size resolution proceeds as follows:

1. If root width and height both resolve positively, use both.
2. If exactly one resolves and a positive `viewBox` is usable, derive the
   missing axis using the viewBox aspect ratio. If no usable viewBox exists,
   use 300 for a missing width or 150 for a missing height.
3. If neither resolves, use the positive viewBox width and height when present;
   otherwise use 300 by 150.

The document's `preserveAspectRatio` (default `xMidYMid meet`) governs drawing
the viewBox inside this intrinsic viewport. It is separate from the outer
profile fit described below.

Output size precedence is fixed:

1. Both `width` and `height`: use that exact canvas.
2. `width` only: derive height from the intrinsic aspect ratio.
3. `height` only: derive width from the intrinsic aspect ratio.
4. `scale` only: multiply both intrinsic dimensions by the exact scale.
5. Empty profile: use intrinsic dimensions.

Round each derived positive dimension by `floor(value + 1/2)`. Clamp a positive
result below one pixel to one. Do not clamp zero or invalid source values into
valid output. Check dimensions, pixel count, row stride, and output-buffer
arithmetic after rounding and before the corresponding allocation. RGBA8 row
stride is `width * 4`; all multiplications and sums are checked for overflow.

Preserve the intrinsic aspect ratio. For an exact two-axis canvas, compute
`fit = min(output_width / intrinsic_width, output_height / intrinsic_height)`.
Scale both viewport axes by `fit` and center them using translations
`(output_width - scaled_width) / 2` and
`(output_height - scaled_height) / 2`. Pass those values to the native transform.
Never stretch axes independently. The outer fit does not replace the SVG's own
viewBox `preserveAspectRatio` behavior.

The default background is transparent black. Accepted strings are exactly
`transparent`, `#RRGGBB`, and `#RRGGBBAA`; expand six hex digits with alpha `FF`.
For each channel, premultiply using integer division:
`(channel * alpha + 127) / 255`. Fill the complete canvas, including letterbox
areas, with that premultiplied color before compositing the SVG source-over.
There is no background operation after RGBA unpremultiplication.

Required profile fixtures include the 300 by 150 no-size/no-viewBox default,
viewBox-only dimensions, one-axis derivation, both-axis fitting and padding,
scale, half-pixel rounding, transparent and explicit-alpha backgrounds, and
each rejected key, type, value, limit, and incompatible combination.

## Fonts and diagnostics

System-font loading is disabled and the package bundles no fonts. Normalize
family matching with Unicode NFC, CSS quote removal, whitespace collapse, and
ASCII case folding. Every `fonts` key must match at least one family name found
in its supplied face metadata. Reject malformed fonts and duplicate normalized
family/style/weight/stretch faces; do not break ties using hash iteration or
filesystem order.

The resolver uses resvg's computed CSS family, style, weight, and stretch
request. Within an exact requested family it follows the pinned resvg/fontdb
face-matching algorithm. For each shaped cluster, first select an exact-family
face with full cluster coverage. If none covers it, consider `fallback_fonts`
strictly in caller order and match style, weight, and stretch within each
fallback family. The face selected by the resolver callback must be the face
resvg actually shapes and renders; an independent preflight guess is
insufficient. If no supplied face covers a cluster, raise `MissingGlyphError`
with the requested family and missing Unicode scalars.

Emit substitution warnings in first document-use order. Deduplicate by
requested family, selected family, style/weight/stretch, and missing scalar set.
Each warning names requested and selected families and the triggering scalars.
The result's font manifest reports resolved face/source diagnostics and
byte-derived SHA-256 digests. It does not promise that metadata extraction or
the native selection hook is implemented in the current shell.

## SVG references and parser boundary

At the raw render byte boundary, reject every XML `DOCTYPE` declaration before
DOM construction or entity expansion. The guard must be token-aware so
`DOCTYPE` text in comments or CDATA is not mistaken for a declaration. Permit
same-document fragments such as `href="#symbol"` and `url(#gradient)`, and
inline `data:` values already contained in the SVG bytes. Reject malformed URI
syntax as `InputError`.

The pinned XML/CSS parser boundary rejects relative and absolute paths,
drive and UNC paths, traversal or symlink-looking paths, protocol-relative
URLs, `file:`, `http:`, `https:`, every other non-`data:` scheme, and CSS
`@import` before any resolver or decoder can request external bytes. Apply this
rule to all URI-bearing SVG attributes and CSS `url(...)`. The rejection patch
returns a stable forbidden-reference status and reference class/document
location without echoing sensitive host content. It accepts no resource bytes
and provides no loader callback. Leave resvg's filesystem resources directory
unset; do not change working directory, materialize files, or use an HTTP
client. Tests must prove forbidden inputs fail without filesystem or socket
access, including concurrent renders. Positive controls cover inline `data:`
raster values and same-document fragments.

## Limits and unsupported SVG behavior

Enforce these fixed limits before the associated allocation:

| Resource | Limit |
| --- | ---: |
| SVG input bytes | 16 MiB |
| Font faces in one request | 64 |
| One font's bytes | 32 MiB |
| Total font bytes in one request | 128 MiB |
| Output width or height | 32768 pixels |
| Output pixels | 64,000,000 |
| Row stride and output buffer | checked arithmetic; buffer <= 256 MiB |

Count/byte limits are checked before parsing or copying their associated data;
dimension, pixel, stride, and output-buffer checks happen after size resolution
and before allocation. `LimitError` covers only these enforceable checks.
There is no safe cancellation API for the synchronous resvg call, so there is
no in-process render-time deadline. Callers who need a wall-clock bound must
render in a killable isolated process. Static constructs unsupported by the
pinned resvg release retain resvg's documented behavior; Svgpng does not
promise a blanket error for every ignored or unsupported construct.

## Native ownership and packaging decision

The intended native pipeline is owned as follows; paths are proposed until the
scaffold is implemented and must be reconciled if final repository layout
differs:

* `native/svgpng_shim/` owns the sole narrow C ABI, native allocations and
  frees, status mapping, font-byte loading/resolver callback, render buffer,
  unpremultiplication, and PNG encoding. Ruby never frees memory allocated by
  a different allocator.
* The intended Claricle-maintained resvg fork is based on upstream **v0.48.1**
  and contains only the reviewable font-selection/diagnostic hook and
  parser-side rejection of forbidden references. The upstream release archive
  is now staged and checksum-verified as recorded in `vendor/manifest.yml`;
  the custom fork, patch set, and their license closure are still pending. The
  upstream C API alone is not assumed to enforce this contract.
* The shim statically links the fork, **libpng 1.6.59**, and **zlib 1.3.2**.
  The packaged shared library is the dependency closure; neither Fiddle nor the
  dynamic loader may resolve ambient copies of these libraries.
* `lib/svgpng/native.rb` binds only the C ABI through Fiddle;
  `lib/svgpng/renderer.rb` coordinates Ruby input validation and native calls.
  Do not compile at gem install time, add a compiled Ruby extension, shell out,
  or search system library paths.
* `vendor/manifest.yml` records verified source provenance as it becomes
  available. The upstream archive and upstream base commit are pinned there;
  the exact fork commit, patch digests, complete source/license closure,
  the toolchain actually used for a build, linker/build flags, binary
  checksums, and artifact sizes remain unset until measured during native
  implementation. Upstream declares Rust 1.85.0 as its minimum; an isolated
  1.85.0 toolchain is installed for this work but has not yet been used to
  build. This document does not invent a fork commit, source hash, toolchain
  identifier, or patch digest.

### Local macOS renderer build

`rake native:build_renderer` is a developer-only, host build helper. It
requires explicit `SVGPNG_CARGO_HOME`, `SVGPNG_RUSTUP_HOME`,
`SVGPNG_LIBPNG_PREFIX`, `SVGPNG_ZLIB_PREFIX`, and
`SVGPNG_RENDERER_OUTPUT` values. The Cargo invocation is locked and offline;
the dependency prefixes must contain `include/png.h` plus `lib/libpng16.a`
and `include/zlib.h` plus `lib/libz.a`. It combines the Rust static library
with `native/svgpng_shim/rgba.c` and `encoder.c` and links those exact PNG and
zlib archives. The output must be a `.dylib` under `/private/tmp`; this task
does not populate `lib/svgpng/native/`, create a gem, cross-compile, or qualify
a release target. Apple framework and system-library flags are local linker
inputs. Rust's reported native static-library requirements on the macOS build
host were `-lSystem -lc -lm`; no Apple frameworks were reported.

### Local macOS developer package

`rake native:local_package` builds one temporary, developer-labeled
`arm64-darwin` gem from the Ruby shell and an explicitly supplied `.dylib`.
Set `SVGPNG_TEST_NATIVE_LIBRARY` to that built artifact,
`SVGPNG_DEV_PACKAGE_DIR` to an empty directory below `/private/tmp`, and
`SVGPNG_DEV_LABEL` to a short identifier for the build. The task rejects
non-regular or symlinked inputs, inspects `otool -L`, and permits only the
system runtime dependency; libpng and zlib must be statically linked. It stages
the gem without modifying `lib/svgpng/native/`, checks its gem metadata and
payload, installs it locally into an isolated `GEM_HOME`, and runs a 2-by-3
render smoke test using only the installed gem. The package SHA-256 and
diagnostic output are written beside the gem. This verifies one local package
and installed API path; it is not release qualification, a published download
check, or evidence for any other target.

The initial package set is seven native gems and one shell gem, all at the same
version, initially **0.1.0**:

| RubyGems platform | Native package |
| --- | --- |
| `arm64-darwin` | one shared library |
| `x86_64-darwin` | one shared library |
| `x86_64-linux` | one shared library |
| `aarch64-linux` | one shared library |
| `x86_64-linux-musl` | one shared library |
| `aarch64-linux-musl` | one shared library |
| `x64-mingw-ucrt` | one shared library |
| `ruby` | Ruby API and errors only; no native library |

One native artifact serves every supported Ruby version for its platform. On a
supported target, RubyGems should select the matching native package when the
complete set is available. On other targets, the `ruby` shell installs and
loads without probing ambient libraries; rendering raises
`UnsupportedPlatformError` with the detected platform and supported targets.
Do not advertise a native target until that target passes the byte-identity
gate.

## PNG byte profile

resvg supplies premultiplied RGBA8 rows in top-to-bottom order. For every
component, including alpha zero, convert to straight RGBA as follows:

```text
if alpha == 0: straight = 0
else: straight = min(255, (premultiplied * 255 + alpha / 2) / alpha)
```

Use checked integer arithmetic. Treat resulting channels as sRGB sample values;
perform no gamma or color-profile transform. Background compositing is already
complete in resvg before this conversion.

Encode PNG color type 6 (RGBA), bit depth 8, no interlace, and
`PNG_FILTER_NONE`. Use zlib level 9, default strategy, window 15, memory level
8, and a 32 KiB libpng compression buffer. Emit only the PNG signature,
`IHDR`, one or more deterministic `IDAT` chunks, and `IEND`, in that order.
Omit time, text, DPI, gamma, chromaticity, sRGB, ICC, EXIF, and every other
ancillary chunk. Golden tests must inspect structure and chunk order as well as
the complete file digest.

The exact chunk boundaries and compression output are to be pinned and proved
by the encoder implementation and golden fixtures. These settings define the
required profile; they do not constitute evidence of delivered byte identity.

## Delivery and evidence gates

The required implementation sequence is captured by owned cards 01, 02, 03,
and 05 in the Vectory `TODO.svg-to-png` plan. Card 01 establishes the Ruby
contract and focused profile examples. Card 03 proves the font-selection and
forbidden-reference hooks. Card 02 builds an unpublished, checksummed local
candidate set of all seven native gems plus the shell, including a native gem
for Vectory's development/CI platform. Card 05 proves repeated exact output on
all seven targets and verifies the staged artifacts by checksum. Until those
gates pass, native delivery and support remain pending; no 0.1.0 publication or
cross-platform determinism claim follows from this design document.

The bounded golden corpus must record fixture source and licence, complete
profile, SVG/font digests and normalized metadata, resvg fork/upstream/patch
identifiers, libpng/zlib/toolchain/build identifiers, encoding settings,
expected dimensions, ordered warnings/errors, and expected SHA-256. Positive
fixtures cover dimensions/viewBox, paths and strokes, gradients/clips/masks,
alpha/background, unpremultiplication edges, inline raster data, fragments,
exact fonts, face matching, ordered fallback, partial coverage, warning order,
and enforceable limits. Negative fixtures cover malformed input, missing font
or glyph, prohibited references, limits, loader/native failures, and encoding
failures. Representative unsupported static constructs pin documented resvg
output behavior without asserting a universal error. Each positive case renders
twice in a clean process and must match its committed PNG byte-for-byte on all
seven targets. Host fonts, locale, timezone, working directory, environment,
and render order/concurrency must not change bytes or warnings.

The artifact set is immutable after the gate. Verify that the seven native gems
and shell gem match staged SHA-256 values; do not rebuild for publication.
Publication is one eight-file release set, followed by clean package-resolution
checks proving native selection and a minimal golden on a supported target and
shell selection, successful require, and render-time unsupported-platform
failure on an unsupported target. Golden updates require an explicit
compatibility change; before 1.0, a byte change requires a minor version bump
and changelog entry, and from 1.0 it requires a major version bump (working
rule pending confirmation).

Current verification state: focused examples exercise the Ruby shell, exact
profiles, standalone input guards, ordered warning collection, C pixel conversion,
native ABI ownership controls, and release/package-resolution verification.
The shell builds, installs, and loads with an empty executable search path; its
render call raises the documented unsupported-platform error. The release-set
specs build real gem containers with synthetic native payloads. They exercise
metadata, full-index resolution and installation, not usable native packages.
The encoder source rejects dependency versions other than libpng 1.6.59 and
zlib 1.3.2; its real encode/fault tests require those explicit static installations.
Native renderer compilation, actual PNG encoder behavior, real native package resolution,
clean-target renders, real staged artifact checksums, golden parity, publication,
and all seven support gates remain pending.

### Initial Ruby preflight representation

The Ruby raw-input guard currently accepts UTF-8 XML bytes (including an optional
UTF-8 BOM); invalid UTF-8 and NUL-bearing encodings raise `InputError` before parsing.
The native parser and URI/CSS policy remain pending and are not replaced by this guard.
Other XML encodings are a current guard limitation, not a finalized restriction
on the byte-oriented render contract.
Intrinsic numeric tokens are bounded to 1024 bytes and an absolute decimal exponent
of 4096 before rational construction (`LimitError`); values overflowing finite IEEE
754 magnitude are invalid (`ProfileError`). Positive underflow remains exact for
rounding and the one-pixel clamp. These limits prevent unbounded big-integer parsing.
