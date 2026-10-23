# Native renderer bridge

This crate exposes only the synchronous C ABI in `include/renderer.h`. Inputs are
borrowed for the call; returned pixel/JSON buffers belong to Rust and must be freed
with `svgpng_v1_render_free`. Every call owns its font database, diagnostics, and
resource budget. No renderer executable, system font search, or file image resolver
is enabled. The `background_rgba` word is premultiplied RGBA in big-endian channel
order, as supplied by the Ruby render profile.

`upstream/` contains the resvg/usvg library sources and both upstream licenses
from the verified resvg v0.48.1 release archive. It is an isolated embedding fork,
not an unmodified upstream release. Patch provenance and the reproducible unified
diff are in `../patches/`. Upstream command-line crates and vendored dependencies
are deliberately omitted. Cargo.lock pins this bridge's complete dependency
resolution; it is not the upstream release lockfile.

The embedding patch checks original XML, every reference attribute, tokenized CSS,
and nested SVG/data resources before conversion; disables filesystem resolution;
threads explicit font resolver callbacks into nested parsing; and substitutes whole
shaping clusters using candidate text shaped in original bidi/text context. Font
SVG glyph documents are checked before use, including paths that create default
upstream Options. Only supplied bytes enter fontdb, and actual selected faces are
reported. Missing requested families or unresolved clusters return typed statuses.
This source fork is local; publication and multi-platform qualification are separate.

Build with Rust 1.85 or newer:

```sh
cargo test --manifest-path native/svgpng_renderer/Cargo.toml --locked --lib
cargo test --manifest-path native/svgpng_renderer/Cargo.toml --locked -p usvg \
  --lib --no-default-features --features text parser::policy::tests
cargo rustc --manifest-path native/svgpng_renderer/Cargo.toml --locked \
  --release --lib -- --print native-static-libs
```

The resulting `target/release/libsvgpng_renderer.a` links with the separately built
C pixel conversion/PNG encoder bridge. On the tested arm64-darwin Rust 1.85 target,
rustc reports `-lSystem -lc -lm`; other targets must use their own rustc output.
