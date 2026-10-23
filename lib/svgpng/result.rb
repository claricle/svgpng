# frozen_string_literal: true

module Svgpng
  # Native diagnostics are copied into immutable Ruby values before native free.
  module Immutable
    def self.copy(value)
      case value
      when String then value.dup.freeze
      when Array then value.map { |item| copy(item) }.freeze
      when Hash then value.to_h { |key, item| [copy(key), copy(item)] }.freeze
      when Integer, Symbol, NilClass, TrueClass, FalseClass then value
      else raise InputError, "Unsupported diagnostic value #{value.class}"
      end
    end
  end

  # One ordered native font substitution event.
  class FontSubstitutionWarning
    attr_reader :requested_family, :selected_family, :style, :weight, :stretch, :scalars

    # rubocop:disable-next Metrics/ParameterLists -- Mirrors the public native diagnostic fields.
    def initialize(requested_family:, selected_family:, style:, weight:, stretch:, scalars:)
      @requested_family = Immutable.copy(requested_family)
      @selected_family = Immutable.copy(selected_family)
      @style = Immutable.copy(style)
      @weight = Immutable.copy(weight)
      @stretch = Immutable.copy(stretch)
      @scalars = Immutable.copy(scalars)
      freeze
    end
  end

  # Rendered bytes and diagnostics without native ownership.
  class Result
    attr_reader :png_bytes, :width, :height, :warnings, :font_manifest

    def initialize(png_bytes:, width:, height:, warnings: [], font_manifest: [])
      @png_bytes = png_bytes.b.freeze
      @width = width
      @height = height
      unless warnings.is_a?(Array) && warnings.all?(FontSubstitutionWarning)
        raise InputError, "Warnings must be FontSubstitutionWarning values"
      end

      @warnings = warnings.dup.freeze
      @font_manifest = Immutable.copy(font_manifest)
      freeze
    end
  end
end
