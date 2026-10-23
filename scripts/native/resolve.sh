#!/usr/bin/env bash
set -euo pipefail
: "${SVGPNG_TARGET:?Set exact gem target}"
export SVGPNG_RELEASE_DIR="$PWD/release-set"
export SVGPNG_RELEASE_MANIFEST="$SVGPNG_RELEASE_DIR/checksums.json"
export SVGPNG_RESOLUTION_DESTINATION="$PWD/tmp/resolution-install"
bundle exec rake svgpng:verify_package_resolution
env -u RUBYOPT -u RUBYLIB -u BUNDLE_BIN_PATH -u BUNDLE_GEMFILE \
  GEM_HOME="$SVGPNG_RESOLUTION_DESTINATION" GEM_PATH="$SVGPNG_RESOLUTION_DESTINATION" \
  ruby scripts/native/smoke.rb "$SVGPNG_TARGET"
