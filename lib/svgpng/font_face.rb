# frozen_string_literal: true

require "digest"

module Svgpng
  # A byte container. Only the pinned native parser may assert face metadata.
  class FontFace
    attr_reader :bytes, :source_id, :sha256

    def initialize(bytes:, source_id:)
      validate_bytes!(bytes)
      raise InputError, "Font source_id must be a nonempty String" unless source_id.is_a?(String) && !source_id.empty?

      @bytes = bytes.b.freeze
      @source_id = source_id.dup.freeze
      @sha256 = Digest::SHA256.hexdigest(@bytes).freeze
      freeze
    end

    private

    def validate_bytes!(bytes)
      raise FontMetadataError, "Font bytes must be a nonempty String" unless bytes.is_a?(String) && !bytes.empty?
      raise LimitError, "Font exceeds #{Limits::FONT_BYTES} bytes" if bytes.bytesize > Limits::FONT_BYTES
    end
  end
end
