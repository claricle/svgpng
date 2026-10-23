# frozen_string_literal: true

module Svgpng
  # Coordinates the owned native renderer and deterministic PNG encoder.
  class Renderer
    SUPPORTED_TARGETS = %w[arm64-darwin x86_64-darwin x86_64-linux aarch64-linux
                           x86_64-linux-musl aarch64-linux-musl x64-mingw-ucrt].map(&:freeze).freeze

    # Preserve the pipeline order: parse, resolve, render, convert, encode, copy.
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def self.render(svg_bytes, profile:, fonts:, fallback_fonts:)
      require_relative "native"
      library = Native.load
      source = RawInput.validate!(svg_bytes)
      settings = RenderProfile.new(profile)
      inputs = FontInputs.new(fonts: fonts, fallback_fonts: fallback_fonts)
      layout = settings.resolve(library.root_attributes(source))
      pixels, diagnostics = library.render_pixels(source, layout: layout, fonts: inputs)
      straight = library.rgba_to_straight(pixels, width: layout.width, height: layout.height)
      png = library.encode_rgba(straight, width: layout.width, height: layout.height)
      warnings = FontWarnings.new
      diagnostics.fetch("warnings", []).each { |warning| warnings.add(**warning.transform_keys(&:to_sym)) }
      Result.new(png_bytes: png, width: layout.width, height: layout.height,
                 warnings: warnings.warnings, font_manifest: diagnostics.fetch("font_manifest", []))
    end
  end
end
