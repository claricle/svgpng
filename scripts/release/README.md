# Publishing the qualified SVGPNG 0.1.2 set

Run `.github/workflows/release.yml` on `main` with `dry_run: true` first.
This verifies qualification run 43652981982 and artifact 14137490517, then
checks the fixed approved manifest and all eight immutable gem files using
`Svgpng::ReleaseSet`. No build or version change occurs. The source tree is
83f028527dcdbd89b14d1d9a121d6b450b06a712.
Qualification includes all seven native builds, package assembly, platform
installation checks, and Ruby 4 installation with the declared Fiddle dependency.
The artifact expires on 2026-11-28; expiry is a failure, never a
reason to rebuild or select a different artifact automatically.

For the authorized release, dispatch with `dry_run: false`. RubyGems must have
a Trusted Publisher for owner `claricle`, repository `svgpng`, workflow
`release.yml`, with environment empty. Only the publishing job requests an OIDC
token. Missing publisher authentication blocks publication; no API key secret
is needed. This workflow creates no tag or GitHub Release.

Publication stops on the first failure. A retry skips an already published gem
only after its downloaded bytes match the approved local bytes. Each new push
is followed by the same byte comparison. A conflicting remote gem fails the
release. After publication, complete the documented clean native-selection,
render, unsupported-platform shell, and downstream PNGConform checks before
claiming consumer acceptance.
