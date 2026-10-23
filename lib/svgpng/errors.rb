# frozen_string_literal: true

module Svgpng
  class Error < StandardError; end
  class InputError < Error; end
  class ProfileError < InputError; end
  class LimitError < InputError; end
  class FontError < InputError; end
  class FontMetadataError < FontError; end
  class DuplicateFontError < FontError; end

  # An unresolved requested family, optionally identified by native diagnostics.
  class MissingFamilyError < FontError
    attr_reader :requested_family

    def initialize(message = nil, requested_family: nil)
      @requested_family = requested_family&.dup&.freeze
      super(message)
    end
  end

  # Missing Unicode scalar values for an explicitly requested family.
  class MissingGlyphError < FontError
    attr_reader :requested_family, :scalars

    def initialize(message = nil, requested_family: nil, scalars: nil)
      @requested_family = requested_family&.dup&.freeze
      @scalars = scalars&.dup&.freeze
      super(message)
    end
  end

  # A rejected reference, with structural identifiers rather than resource paths.
  class ForbiddenReferenceError < InputError
    attr_reader :reference_class, :location

    def initialize(message = nil, reference_class: nil, location: nil)
      @reference_class = reference_class&.dup&.freeze
      @location = location&.dup&.freeze
      super(message)
    end
  end

  class NativeError < Error; end
  class EncodingError < NativeError; end

  # Raised only when a native-free shell is asked to render.
  class UnsupportedPlatformError < Error
    attr_reader :platform, :supported_targets

    def initialize(platform:, supported_targets:)
      @platform = platform.dup.freeze
      @supported_targets = supported_targets.map { |target| target.dup.freeze }.freeze
      super("No packaged SVGPNG renderer for #{platform}; supported targets: #{supported_targets.join(", ")}")
    end
  end
end
