# frozen_string_literal: true

module Svgpng
  class Error < StandardError; end
  class InputError < Error; end
  class ProfileError < InputError; end
  class LimitError < InputError; end
  class FontError < InputError; end
  class FontMetadataError < FontError; end
  class DuplicateFontError < FontError; end
  class MissingFamilyError < FontError; end
  class MissingGlyphError < FontError; end
  class ForbiddenReferenceError < InputError; end
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
