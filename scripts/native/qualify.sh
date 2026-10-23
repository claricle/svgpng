#!/usr/bin/env bash
set -euo pipefail
: "${SVGPNG_TARGET:?Set exact gem target}"
python3 scripts/native/build.py "$SVGPNG_TARGET" --work "$PWD/tmp/native-build" --output "$PWD/candidate"
case "$SVGPNG_TARGET" in
  *darwin) suffix=dylib ;;
  *mingw*) suffix=dll ;;
  *) suffix=so ;;
esac
export SVGPNG_TEST_NATIVE_LIBRARY="$PWD/candidate/svgpng.$suffix"
export SVGPNG_REQUIRE_GOLDENS=1
bundle exec ruby scripts/native/abi.rb "$SVGPNG_TEST_NATIVE_LIBRARY"
bundle exec rake svgpng:verify_manifest
bundle exec rspec spec/svgpng/golden_spec.rb
ruby scripts/native/package.rb "$SVGPNG_TARGET" "$SVGPNG_TEST_NATIVE_LIBRARY" candidate
# Remove Bundler's source checkout activation for a genuinely isolated install.
install_dir="$PWD/tmp/clean-install"
mkdir -p "$install_dir"
env -u RUBYOPT -u RUBYLIB -u BUNDLE_BIN_PATH -u BUNDLE_GEMFILE GEM_HOME="$install_dir" GEM_PATH="$install_dir" \
  gem install --local --no-document --ignore-dependencies --install-dir "$install_dir" "candidate/svgpng-0.1.0-$SVGPNG_TARGET.gem"
env -u RUBYOPT -u RUBYLIB -u BUNDLE_BIN_PATH -u BUNDLE_GEMFILE GEM_HOME="$install_dir" GEM_PATH="$install_dir" \
  ruby scripts/native/smoke.rb "$SVGPNG_TARGET"
