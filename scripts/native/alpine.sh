#!/usr/bin/env sh
set -eu
apk add --no-cache bash build-base binutils cmake ninja python3 ruby ruby-dev ruby-bundler yaml-dev libffi-dev curl git linux-headers
git config --global --add safe.directory "$PWD"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain 1.85.0
export PATH="$HOME/.cargo/bin:$PATH"
bundle config set --local path /tmp/svgpng-bundle
bundle install
bash "scripts/native/${SVGPNG_OPERATION:-qualify}.sh"
