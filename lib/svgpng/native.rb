# frozen_string_literal: true

require_relative "errors"
require_relative "render_profile"
require "fiddle"
require "fiddle/struct"

module Svgpng
  # Opens only the artifact belonging to this installed gem, on explicit request.
  module Native
    SUPPORTED_TARGETS = %w[arm64-darwin x86_64-darwin x86_64-linux aarch64-linux
                           x86_64-linux-musl aarch64-linux-musl x64-mingw-ucrt].map(&:freeze).freeze
    SUFFIXES = { "darwin" => "dylib", "linux" => "so", "mingw" => "dll" }.freeze

    def self.load
      Library.new
    end

    def self.packaged_library_path
      platform = Gem::Platform.local
      target = SUPPORTED_TARGETS.find { |candidate| candidate == platform.to_s }
      target ||= compatible_target(platform)
      raise UnsupportedPlatformError.new(platform: platform.to_s, supported_targets: SUPPORTED_TARGETS) unless target

      suffix = SUFFIXES.fetch(platform.os)
      File.join(File.realpath(__dir__), "native", target, "svgpng.#{suffix}")
    end
    private_class_method :packaged_library_path

    def self.compatible_target(platform)
      SUPPORTED_TARGETS.find do |name|
        candidate = Gem::Platform.new(name)
        next false unless candidate.cpu == platform.cpu && candidate.os == platform.os

        case platform.os
        when "darwin" then true
        when "linux" then candidate.version == (platform.version == "gnu" ? nil : platform.version)
        else false
        end
      end
    end
    private_class_method :compatible_target

    # This binding is a pixel conversion primitive, not a rendering backend.
    # Keep the two ownership-related ABI primitives and their guards in one binding.
    # rubocop:disable-next Metrics/ClassLength
    class Library
      SIZE_MAX = (1 << (Fiddle::SIZEOF_SIZE_T * 8)) - 1
      POINTER_MAX = (1 << (Fiddle::SIZEOF_VOIDP * 8)) - 1
      STATUS_ERRORS = { 1 => InputError, 2 => LimitError, 3 => LimitError,
                        4 => InputError, 5 => InputError }.freeze
      STATUS_NAMES = { 1 => "invalid argument", 2 => "arithmetic overflow", 3 => "limit exceeded",
                       4 => "buffer too small", 5 => "overlapping buffers" }.freeze
      PNG_OUTPUT = Fiddle::CStructBuilder.create(Fiddle::CStruct, [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T],
                                                 %w[bytes length])
      PNG_STATUS_ERRORS = { 1 => InputError, 2 => LimitError, 3 => LimitError, 4 => InputError,
                            5 => EncodingError, 6 => EncodingError, 7 => NativeError }.freeze
      PNG_STATUS_NAMES = { 1 => "invalid argument", 2 => "arithmetic overflow", 3 => "limit exceeded",
                           4 => "buffer too small", 5 => "allocation failed", 6 => "encoding failed",
                           7 => "dependency version mismatch" }.freeze

      def initialize
        path = Native.send(:packaged_library_path)
        check_packaged_file(path)
        @handle = Fiddle::Handle.new(path, Fiddle::RTLD_NOW)
        arguments = [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_SIZE_T,
                     Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_SIZE_T,
                     Fiddle::TYPE_SIZE_T, Fiddle::TYPE_SIZE_T]
        @convert = Fiddle::Function.new(@handle["svgpng_v1_rgba_to_straight"], arguments, Fiddle::TYPE_INT)
      rescue Fiddle::DLError => e
        raise NativeError, "Cannot load packaged SVGPNG RGBA ABI: #{e.message}"
      end

      def rgba_to_straight(source, width:, height:, source_stride: nil, destination_stride: nil)
        source_stride = width.is_a?(Integer) ? width * 4 : nil if source_stride.nil?
        destination_stride = width.is_a?(Integer) ? width * 4 : nil if destination_stride.nil?
        source_bytes, destination_bytes = validate_buffers(source, width, height, source_stride, destination_stride)
        convert(source, width, height, source_stride, destination_stride, source_bytes, destination_bytes)
      end

      def encode_rgba(source, width:, height:, source_stride: nil)
        source_stride = width.is_a?(Integer) ? width * 4 : nil if source_stride.nil?
        source_bytes = validate_buffers(source, width, height, source_stride, source_stride).first
        encode_png(source, source_bytes, source_stride, width, height)
      end

      private

      def encoder_functions
        @encoder_functions ||= begin
          arguments = [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_SIZE_T,
                       Fiddle::TYPE_SIZE_T, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_VOIDP]
          encode = Fiddle::Function.new(@handle["svgpng_v1_png_encode"], arguments, Fiddle::TYPE_INT)
          release = Fiddle::Function.new(@handle["svgpng_v1_png_free"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
          [encode, release].freeze
        end
      rescue Fiddle::DLError => e
        raise NativeError, "Cannot load packaged SVGPNG encoder ABI: #{e.message}"
      end

      # Keep shim release ahead of both Ruby buffer releases on every exit path.
      # rubocop:disable-next Metrics/MethodLength, Metrics/AbcSize
      def encode_png(source, source_bytes, source_stride, width, height)
        encode, release = encoder_functions
        output = PNG_OUTPUT.malloc(Fiddle::RUBY_FREE)
        output.bytes = 0
        output.length = 0
        input = Fiddle::Pointer.malloc(source_bytes, Fiddle::RUBY_FREE)
        input[0, source_bytes] = source.byteslice(0, source_bytes)
        status = encode.call(input, source_bytes, source_stride, width, height, output.to_ptr)
        check_png_status(status)
        copy_png(output)
      ensure
        begin
          release.call(output.to_ptr) if output
        ensure
          output&.to_ptr&.call_free
          input&.call_free
        end
      end

      def check_png_status(status)
        return if status.zero?

        message = PNG_STATUS_NAMES.fetch(status, "unknown status #{status}")
        raise PNG_STATUS_ERRORS.fetch(status, NativeError), "SVGPNG PNG encoding: #{message}"
      end

      def copy_png(output)
        length = output.length
        raise NativeError, "PNG encoder returned an empty output" unless length.positive?
        raise LimitError, "PNG encoder output exceeds limits" if length > RenderProfile::MAX_BUFFER_BYTES

        address = output.bytes.to_i
        if !address.positive? || address > POINTER_MAX - length
          raise NativeError, "PNG encoder returned an invalid output pointer"
        end

        Fiddle::Pointer.new(address)[0, length].b
      end

      def check_packaged_file(path)
        unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
          raise UnsupportedPlatformError.new(platform: Gem::Platform.local.to_s, supported_targets: SUPPORTED_TARGETS)
        end
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        raise UnsupportedPlatformError.new(platform: Gem::Platform.local.to_s, supported_targets: SUPPORTED_TARGETS)
      end

      # Keep all pre-allocation ABI guards together for auditing against rgba.c.
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def validate_buffers(source, width, height, source_stride, destination_stride)
        values = [width, height, source_stride, destination_stride]
        unless source.is_a?(String) && values.all? { |value| value.is_a?(Integer) && value.positive? }
          raise InputError, "RGBA source must be bytes with positive integer dimensions and strides"
        end
        raise LimitError, "RGBA integer exceeds size_t" if values.any? { |value| value > SIZE_MAX }
        if width > RenderProfile::MAX_DIMENSION || height > RenderProfile::MAX_DIMENSION ||
           width * height > RenderProfile::MAX_PIXELS
          raise LimitError, "RGBA dimensions exceed limits"
        end
        if [source_stride, destination_stride].min < width * 4
          raise InputError, "RGBA stride is smaller than a pixel row"
        end

        capacities = [source_stride * height, destination_stride * height]
        if capacities.any? { |value| value > SIZE_MAX || value > RenderProfile::MAX_BUFFER_BYTES }
          raise LimitError, "RGBA buffer exceeds limits"
        end
        raise InputError, "RGBA source buffer is too small" if source.bytesize < capacities.first

        capacities
      end

      # Explicit arguments mirror the checked C ABI without a second mutable descriptor.
      # rubocop:disable-next Metrics/ParameterLists, Metrics/MethodLength
      def convert(source, width, height, source_stride, destination_stride, source_bytes, destination_bytes)
        input = Fiddle::Pointer.malloc(source_bytes, Fiddle::RUBY_FREE)
        output = Fiddle::Pointer.malloc(destination_bytes, Fiddle::RUBY_FREE)
        input[0, source_bytes] = source.byteslice(0, source_bytes)
        output[0, destination_bytes] = "\0".b * destination_bytes
        status = @convert.call(input, source_bytes, source_stride, output, destination_bytes, destination_stride,
                               width, height)
        check_status(status)
        output[0, destination_bytes].b
      ensure
        output&.call_free
        input&.call_free
      end

      def check_status(status)
        return if status.zero?

        message = STATUS_NAMES.fetch(status, "unknown status #{status}")
        raise STATUS_ERRORS.fetch(status, NativeError), "SVGPNG RGBA conversion: #{message}"
      end
    end
  end
end
