# frozen_string_literal: true

module Svgpng
  # Shell implementation; native packages supply the owned rendering ABI.
  class Renderer
    SUPPORTED_TARGETS = %w[arm64-darwin x86_64-darwin x86_64-linux aarch64-linux
                           x86_64-linux-musl aarch64-linux-musl x64-mingw-ucrt].map(&:freeze).freeze

    def self.render(_svg_bytes, **_options)
      # The ruby-platform shell does not probe or load ambient native libraries.
      raise UnsupportedPlatformError.new(platform: Gem::Platform.local.to_s,
                                         supported_targets: SUPPORTED_TARGETS)
    end
  end
end
