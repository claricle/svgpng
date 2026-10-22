# frozen_string_literal: true

require_relative "result"

module Svgpng
  # Collects ordered substitution diagnostics emitted by a renderer.
  class FontWarnings
    def initialize
      @warnings = []
      @keys = {}
    end

    # rubocop:disable-next Metrics/ParameterLists -- Mirrors the native event fields.
    def add(requested_family:, selected_family:, style:, weight:, stretch:, scalars:)
      normalized_scalars = normalize_scalars(scalars)
      warning = FontSubstitutionWarning.new(requested_family: requested_family,
                                            selected_family: selected_family,
                                            style: style, weight: weight,
                                            stretch: stretch, scalars: normalized_scalars)
      key = [warning.requested_family, warning.selected_family, warning.style,
             warning.weight, warning.stretch, warning.scalars]
      @warnings << warning unless @keys.key?(key)
      @keys[key] = true
      warning
    end

    def warnings
      @warnings.dup.freeze
    end

    private

    def normalize_scalars(scalars)
      unless scalars.is_a?(Array) && scalars.all? { |scalar| valid_scalar?(scalar) }
        raise ArgumentError, "scalars must be Unicode scalar values (0..0x10FFFF, excluding surrogates)"
      end

      scalars.uniq.sort.freeze
    end

    def valid_scalar?(scalar)
      scalar.is_a?(Integer) && scalar.between?(0, 0x10FFFF) && !scalar.between?(0xD800, 0xDFFF)
    end
  end
end
