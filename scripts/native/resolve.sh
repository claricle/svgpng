#!/usr/bin/env bash
set -euo pipefail
: "${SVGPNG_TARGET:?Set exact gem target}"
export SVGPNG_RELEASE_DIR="$PWD/release-set"
export SVGPNG_RELEASE_MANIFEST="$SVGPNG_RELEASE_DIR/checksums.json"
export SVGPNG_RESOLUTION_DESTINATION="$PWD/tmp/resolution-install"
bundle exec rake svgpng:verify_package_resolution
smoke_gem_path="$(SVGPNG_SMOKE_INSTALL_DIR="$SVGPNG_RESOLUTION_DESTINATION" bundle exec ruby -e 'puts [ENV.fetch("SVGPNG_SMOKE_INSTALL_DIR"), Gem.loaded_specs.fetch("fiddle").base_dir].join(File::PATH_SEPARATOR)')"
env -u RUBYOPT -u RUBYLIB -u BUNDLE_BIN_PATH -u BUNDLE_GEMFILE \
  GEM_HOME="$SVGPNG_RESOLUTION_DESTINATION" GEM_PATH="$smoke_gem_path" \
  ruby scripts/native/smoke.rb "$SVGPNG_TARGET" "$SVGPNG_RESOLUTION_DESTINATION"
