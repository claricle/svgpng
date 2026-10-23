# frozen_string_literal: true

module Svgpng
  # Runs before any XML parser. This is not the native URI/CSS policy.
  module RawInput
    def self.validate!(bytes)
      # Class-side checking and a plain snapshot prevent caller overrides/mutation.
      # rubocop:disable-next Style/CaseEquality
      raise InputError, "SVG input must be a String" unless String === bytes

      bytes = String.new(bytes)
      raise LimitError, "SVG exceeds #{Limits::SVG_BYTES} bytes" if bytes.bytesize > Limits::SVG_BYTES

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise InputError, "SVG must contain UTF-8 XML bytes" unless text.valid_encoding? && !text.include?("\0")

      # Scan byte offsets so repeated delimiters after multibyte text stay linear.
      scan_declarations!(text.force_encoding(Encoding::BINARY))
      text.force_encoding(Encoding::UTF_8).freeze
    end

    def self.scan_declarations!(text)
      cursor = 0
      while (opening = text.index("<", cursor))
        cursor = token_end(text, opening)
      end
    end

    def self.token_end(text, opening)
      return closing(text, "-->", opening + 4) if text[opening, 4] == "<!--"
      return closing(text, "]]>", opening + 9) if text[opening, 9] == "<![CDATA["
      return closing(text, "?>", opening + 2) if text[opening, 2] == "<?"
      if text[opening, 10].match?(/\A<!DOCTYPE(?:\s|\[|>)/)
        raise ForbiddenReferenceError, "XML DOCTYPE declarations are forbidden"
      end

      opening + 1
    end

    def self.closing(text, delimiter, start)
      index = text.index(delimiter, start)
      raise InputError, "Unterminated XML comment, CDATA or instruction" unless index

      index + delimiter.length
    end
    private_class_method :scan_declarations!, :token_end, :closing
  end
end
