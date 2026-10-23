# frozen_string_literal: true

module Svgpng
  # Resolves parser-provided root attributes into a bounded raster canvas.
  # Keep viewport resolution, output fitting, and their shared limits together.
  class RenderProfile # rubocop:disable Metrics/ClassLength
    MAX_DIMENSION = 32_768
    MAX_PIXELS = 64_000_000
    MAX_STRIDE = MAX_DIMENSION * 4
    MAX_BUFFER_BYTES = 256 * 1024 * 1024
    MAX_ROOT_NUMBER_BYTES = 1024
    MAX_ROOT_EXPONENT = 4096
    KEYS = %i[width height scale background].freeze
    DECIMAL = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/
    SVG_NUMBER = /[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?/
    LENGTH = /\A(#{SVG_NUMBER})(px|in|cm|mm|q|pt|pc|%)?\z/
    UNITS = { "px" => 1, "in" => 96, "cm" => Rational(4800, 127),
              "mm" => Rational(480, 127), "q" => Rational(120, 127),
              "pt" => Rational(4, 3), "pc" => 16 }.freeze

    Layout = Struct.new(:width, :height, :intrinsic_width, :intrinsic_height,
                        :scale, :translate_x, :translate_y, :background,
                        keyword_init: true) do
      def transform
        [scale, 0, 0, scale, translate_x, translate_y].freeze
      end

      def stride
        width * 4
      end

      def buffer_bytes
        stride * height
      end
    end

    # Validation must precede capturing the immutable profile values.
    def initialize(profile = {}) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      unless profile.is_a?(Hash) && (profile.keys - KEYS).empty?
        raise ProfileError, "profile must be a hash with symbol width, height, scale, background keys"
      end
      if profile.key?(:scale) && (profile.key?(:width) || profile.key?(:height))
        raise ProfileError, "scale cannot be combined with width or height"
      end

      @width = pixel_dimension(profile, :width)
      @height = pixel_dimension(profile, :height)
      @scale = decimal_scale(profile[:scale]) if profile.key?(:scale)
      @background = parse_background(profile.fetch(:background, "transparent"))
      freeze
    end

    # Build one immutable layout only after all allocation bounds pass.
    def resolve(root_attributes = {}) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      unless root_attributes.is_a?(Hash) && root_attributes.keys.all?(String)
        raise ProfileError, "root attributes must be a hash with string keys"
      end

      source_width, source_height = intrinsic_size(root_attributes)
      width, height = output_size(source_width, source_height)
      check_bounds(width, height)
      scale = [Rational(width, 1) / source_width, Rational(height, 1) / source_height].min
      Layout.new(width: width, height: height, intrinsic_width: source_width,
                 intrinsic_height: source_height, scale: scale,
                 translate_x: (width - (source_width * scale)) / 2,
                 translate_y: (height - (source_height * scale)) / 2,
                 background: @background).freeze
    end

    private

    def pixel_dimension(profile, key)
      return unless profile.key?(key)

      value = profile[key]
      raise ProfileError, "#{key} must be a positive integer" unless value.is_a?(Integer) && value.positive?
      raise LimitError, "#{key} exceeds #{MAX_DIMENSION}" if value > MAX_DIMENSION

      value
    end

    def decimal_scale(value)
      unless value.is_a?(String) && DECIMAL.match?(value)
        raise ProfileError, "scale must be a positive finite base-10 decimal string"
      end

      number = Rational(value)
      raise ProfileError, "scale must be positive" unless number.positive?

      number
    end

    def parse_background(value)
      return [0, 0, 0, 0].freeze if value == "transparent"
      unless value.is_a?(String) && /\A#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?\z/.match?(value)
        raise ProfileError, "background must be transparent, #RRGGBB, or #RRGGBBAA"
      end

      channels = value.delete_prefix("#").scan(/../).map { |channel| channel.to_i(16) }
      alpha = channels.fetch(3, 255)
      [*channels.first(3).map { |channel| ((channel * alpha) + 127) / 255 }, alpha].freeze
    end

    # These branches mirror the public root-dimension precedence contract.
    def intrinsic_size(attributes) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      width = root_length(attributes["width"], 300)
      height = root_length(attributes["height"], 150)
      view_box = parse_view_box(attributes["viewBox"])
      if width && height
        [width, height]
      elsif width
        [width, view_box ? width * view_box[3] / view_box[2] : Rational(150)]
      elsif height
        [view_box ? height * view_box[2] / view_box[3] : Rational(300), height]
      elsif view_box
        view_box.last(2)
      else
        [Rational(300), Rational(150)]
      end
    end

    def root_length(value, percentage_base)
      return if value.nil?

      match = LENGTH.match(value.to_s.strip)
      raise ProfileError, "unsupported root length: #{value.inspect}" unless match

      number = root_number(match[1])
      raise ProfileError, "root dimensions must be positive" unless number.positive?

      unit = match[2]
      number * (unit == "%" ? Rational(percentage_base, 100) : UNITS.fetch(unit, 1))
    end

    def parse_view_box(value)
      return if value.nil?

      text = value.to_s.strip
      # Enforce separators so malformed tokens cannot become a different viewport.
      unless /\A#{SVG_NUMBER}(?:(?:\s*,\s*|\s+)#{SVG_NUMBER}){3}\z/.match?(text)
        raise ProfileError, "viewBox must contain four finite numbers"
      end

      values = text.split(/[\s,]+/).map { |number| root_number(number) }
      values if values[2].positive? && values[3].positive?
    end

    def root_number(value)
      if value.bytesize > MAX_ROOT_NUMBER_BYTES || value.split(/[eE]/).fetch(1, "0").to_i.abs > MAX_ROOT_EXPONENT
        raise LimitError, "root numeric representation exceeds limits"
      end
      raise ProfileError, "root numbers must be finite" unless Float(value).finite?

      Rational(value)
    end

    def output_size(width, height)
      if @width && @height
        [@width, @height]
      elsif @width
        [@width, round_dimension(@width * height / width)]
      elsif @height
        [round_dimension(@height * width / height), @height]
      else
        factor = @scale || 1
        [round_dimension(width * factor), round_dimension(height * factor)]
      end
    end

    def round_dimension(value)
      [(value + Rational(1, 2)).floor, 1].max
    end

    def check_bounds(width, height)
      raise LimitError, "output dimension exceeds #{MAX_DIMENSION}" if [width, height].max > MAX_DIMENSION
      raise LimitError, "output pixel count exceeds #{MAX_PIXELS}" if width * height > MAX_PIXELS
      raise LimitError, "output row stride exceeds #{MAX_STRIDE}" if width * 4 > MAX_STRIDE
      return if width * height * 4 <= MAX_BUFFER_BYTES

      raise LimitError, "output buffer exceeds #{MAX_BUFFER_BYTES} bytes"
    end
  end
end
