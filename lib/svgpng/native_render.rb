# frozen_string_literal: true

require "json"

module Svgpng
  module Native
    # Owns all temporary arguments and copies renderer output before releasing it.
    module RenderBinding # rubocop:disable Metrics/ModuleLength -- Keep ABI layout and ownership guards together.
      SIZE = Fiddle::TYPE_SIZE_T
      PTR = Fiddle::TYPE_VOIDP
      RENDER_OUTPUT = Fiddle::CStructBuilder.create(Fiddle::CStruct, [PTR, SIZE, PTR, SIZE],
                                                    %w[pixels pixels_length diagnostics diagnostics_length])
      FONT = Fiddle::CStructBuilder.create(Fiddle::CStruct, [PTR, SIZE, PTR, SIZE, PTR, SIZE, SIZE],
                                           %w[bytes length requested_family family_length source_id source_id_length
                                              fallback_order])
      OPTIONS = Fiddle::CStructBuilder.create(Fiddle::CStruct,
                                              ([Fiddle::TYPE_INT32_T] * 4) + ([Fiddle::TYPE_DOUBLE] * 5),
                                              %w[abi_version width height background_rgba intrinsic_width
                                                 intrinsic_height fit translate_x translate_y])
      ERRORS = { 1 => InputError, 2 => LimitError, 3 => FontMetadataError, 4 => DuplicateFontError,
                 5 => MissingFamilyError, 6 => MissingGlyphError, 7 => ForbiddenReferenceError,
                 8 => NativeError, 9 => NativeError }.freeze
      DIAGNOSTIC_LIMIT = 4 * 1024 * 1024

      def root_attributes(source)
        renderer_call(source) do |input, output, _owned|
          status = render_functions.fetch(:root).call(input, source.bytesize, output.to_ptr)
          check_render_status(status, output)
          attributes = copy_diagnostics(output)
          unless attributes.is_a?(Hash) && attributes.keys.all?(String) && attributes.values.all?(String)
            raise NativeError, "Renderer returned invalid root attributes"
          end

          attributes
        end
      end

      # One call owns all buffers until both output copies complete.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
      def render_pixels(source, layout:, fonts:)
        renderer_call(source) do |input, output, owned|
          options = render_options(layout, owned)
          entries, count = render_fonts(fonts, owned)
          status = render_functions.fetch(:render).call(input, source.bytesize, entries, count,
                                                        options.to_ptr, output.to_ptr)
          check_render_status(status, output)
          unless output.pixels_length == layout.buffer_bytes
            raise NativeError, "Renderer returned an invalid pixel buffer length"
          end

          pixels = copy_render_bytes(output.pixels, output.pixels_length, RenderProfile::MAX_BUFFER_BYTES)
          diagnostics = copy_diagnostics(output)
          raise NativeError, "Renderer returned invalid diagnostics" unless diagnostics.is_a?(Hash)

          [pixels, diagnostics]
        end
      end

      private

      def render_functions
        @render_functions ||= {
          root: Fiddle::Function.new(@handle["svgpng_v1_root_attributes"], [PTR, SIZE, PTR], Fiddle::TYPE_INT),
          render: Fiddle::Function.new(@handle["svgpng_v1_render"], [PTR, SIZE, PTR, SIZE, PTR, PTR], Fiddle::TYPE_INT),
          free: Fiddle::Function.new(@handle["svgpng_v1_render_free"], [PTR], Fiddle::TYPE_VOID)
        }.freeze
      rescue Fiddle::DLError
        raise NativeError, "Cannot load packaged SVGPNG renderer ABI"
      end

      # Release the shim descriptor before any caller-owned arguments.
      # rubocop:disable-next Metrics/MethodLength
      def renderer_call(source)
        functions = render_functions
        owned = []
        input = own_bytes(source, owned)
        output = RENDER_OUTPUT.new(own_buffer(RENDER_OUTPUT.size, owned))
        output.to_ptr[0, RENDER_OUTPUT.size] = "\0" * RENDER_OUTPUT.size
        yield input, output, owned
      ensure
        begin
          functions.fetch(:free).call(output.to_ptr) if output
        ensure
          owned&.reverse_each(&:call_free)
        end
      end

      def own_buffer(length, owned)
        Fiddle::Pointer.malloc([length, 1].max, Fiddle::RUBY_FREE).tap { |pointer| owned << pointer }
      end

      def own_bytes(bytes, owned)
        pointer = own_buffer(bytes.bytesize, owned)
        pointer[0, bytes.bytesize] = bytes
        pointer
      end

      # Mirror the C ABI fields directly for alignment auditing.
      # rubocop:disable-next Metrics/AbcSize
      def render_options(layout, owned)
        options = OPTIONS.new(own_buffer(OPTIONS.size, owned))
        options.abi_version = 1
        options.width = layout.width
        options.height = layout.height
        options.background_rgba = layout.background.inject(0) { |value, channel| (value << 8) | channel }
        %i[intrinsic_width intrinsic_height translate_x translate_y].each do |key|
          options[key.to_s] = layout.public_send(key).to_f
        end
        options.fit = layout.scale.to_f
        options
      end

      # Keep every borrowed font pointer beside its owned allocation.
      # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
      def render_fonts(inputs, owned)
        faces = inputs.fonts.flat_map { |family, entries| entries.map { |face| [face, family, Library::SIZE_MAX] } }
        faces.concat(inputs.fallback_fonts.each_with_index.map { |face, order| [face, "", order] })
        pointer = own_buffer(FONT.size * faces.length, owned)
        faces.each_with_index do |(face, family, order), index|
          entry = FONT.new(pointer + (index * FONT.size))
          entry.bytes = own_bytes(face.bytes, owned)
          entry.length = face.bytes.bytesize
          entry.requested_family = own_bytes(family, owned)
          entry.family_length = family.bytesize
          entry.source_id = own_bytes(face.source_id, owned)
          entry.source_id_length = face.source_id.bytesize
          entry.fallback_order = order
        end
        [pointer, faces.length]
      end

      def check_render_status(status, output)
        return if status.zero?

        error = ERRORS.fetch(status, NativeError)
        details = render_error_details(status, output)
        raise error.new("SVGPNG rendering failed (status #{status})", **details)
      end

      # Native prose and unknown fields never cross the public error boundary.
      def render_error_details(status, output)
        return {} unless [5, 6, 7].include?(status)

        diagnostics = copy_diagnostics(output)
        detail = diagnostics["error"] if diagnostics.is_a?(Hash)
        return {} unless detail.is_a?(Hash)
        return reference_error_details(detail) if status == 7

        fields = { requested_family: error_family(detail["requested_family"]) }
        fields[:scalars] = error_scalars(detail["scalars"]) if status == 6
        fields
      rescue Error
        {} # Optional diagnostics cannot replace the native status classification.
      end

      def error_family(value)
        return unless value.is_a?(String) && value.bytesize.between?(1, 1024) && value.valid_encoding?
        return if /[[:cntrl:]]/.match?(value)

        value
      end

      def error_scalars(value)
        return unless value.is_a?(Array) && value.length <= 256
        return unless value.all? do |scalar|
          scalar.is_a?(Integer) && scalar.between?(0, 0x10FFFF) && !scalar.between?(0xD800, 0xDFFF)
        end

        value.uniq.sort
      end

      def reference_error_details(detail)
        reference_class = detail["reference_class"]
        location = detail["location"]
        classes = %w[relative absolute file network scheme css_import doctype]
        locations = %w[image@href use@href feImage@href svg@href style@url style@import attribute@url document@doctype]
        { reference_class: classes.include?(reference_class) ? reference_class : nil,
          location: locations.include?(location) ? location : nil }
      end

      def copy_diagnostics(output)
        bytes = copy_render_bytes(output.diagnostics, output.diagnostics_length, DIAGNOSTIC_LIMIT)
        JSON.parse(bytes, max_nesting: 32)
      rescue JSON::ParserError
        raise NativeError, "Renderer returned malformed diagnostics"
      end

      def copy_render_bytes(pointer, length, limit)
        raise LimitError, "Renderer output exceeds limits" if length > limit
        if !length.positive? || !pointer.to_i.positive? || pointer.to_i > Library::POINTER_MAX - length
          raise NativeError, "Renderer returned an invalid output pointer"
        end

        Fiddle::Pointer.new(pointer.to_i)[0, length].b
      end
    end
  end
end
