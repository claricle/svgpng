Third-party source and notices

The pinned rendering sources and patches are recorded in ../manifest.yml.
The complete Cargo.lock registry inventory, including inactive optional workspace
packages, is ../rust-dependencies.json. Each entry records the crate archive URL,
verified SHA-256 checksum, declared license expression, and copied license texts.
The renderer_all_targets_dependency field marks the dependency graph selected by
the renderer's normal/build features across all targets; remaining entries are
locked workspace dependencies that are not selected by that graph.

Rust crate sources are unmodified. Exact corresponding source archives, including
MPL-2.0 sources, are available at the archive_url in each inventory entry. Source
archives can be downloaded and verified with the recorded archive_sha256. Source
license terms remain those of each crate; the local bridge does not relicense them.
The embedded usvg/resvg changes are identified by the recorded upstream patch.

The resvg/ directory contains the upstream Apache-2.0 and MIT license texts.
The libpng/ and zlib/ directories preserve their source distribution licenses.
The fonts/ directory preserves fixture font licenses and embedded copyright
notices. Test fonts are not loaded implicitly by the renderer.

This inventory covers bundled third-party dependencies and test fixtures.
Platform system libraries are supplied by the target operating system.
