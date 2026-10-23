# frozen_string_literal: true

module Svgpng
  # Shape/size checks only: native metadata validation follows before rendering.
  class FontInputs
    attr_reader :fonts, :fallback_fonts

    def initialize(fonts:, fallback_fonts:)
      raise InputError, "fonts must be a Hash" unless fonts.is_a?(Hash)
      raise InputError, "fallback_fonts must be an Array" unless fallback_fonts.is_a?(Array)

      check_count!(fonts, fallback_fonts)
      @fonts = fonts.to_h { |family, faces| normalize_family(family, faces) }.freeze
      @fallback_fonts = validate_faces(fallback_fonts)
      check_total_bytes!

      freeze
    end

    private

    def check_count!(fonts, fallback_fonts)
      count = fallback_fonts.length
      fonts.each_value { |faces| count += faces.is_a?(Array) ? faces.length : 1 }
      raise LimitError, "Too many font faces (maximum #{Limits::FONT_COUNT})" if count > Limits::FONT_COUNT
    end

    def normalize_family(family, faces)
      raise InputError, "Font family keys must be nonempty Strings" unless family.is_a?(String) && !family.strip.empty?

      entries = faces.is_a?(Array) ? faces : [faces]
      raise InputError, "Font family must have at least one face" if entries.empty?

      [family.dup.freeze, validate_faces(entries)]
    end

    def check_total_bytes!
      total = @fonts.values.flatten.sum { |face| face.bytes.bytesize } +
              @fallback_fonts.sum { |face| face.bytes.bytesize }
      raise LimitError, "Total font bytes exceed #{Limits::TOTAL_FONT_BYTES}" if total > Limits::TOTAL_FONT_BYTES
    end

    def validate_faces(faces)
      raise InputError, "Every font must be a Svgpng::FontFace" unless faces.all?(FontFace)

      faces.dup.freeze
    end
  end
end
