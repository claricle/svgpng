# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "rbconfig"
require "zlib"
require "tmpdir"

# Shared read-only corpus operations; ordinary verification never rewrites files.
module GoldenCorpus
  ROOT = File.expand_path("../fixtures/svg_to_png", __dir__)
  RUNNER = File.expand_path("golden_runner.rb", __dir__)
  REPOSITORY = File.expand_path("../..", __dir__)
  FONT_ROOT = File.join(REPOSITORY, "native/svgpng_renderer/tests/fonts")
  ENCODING = { "bit_depth" => 8, "color_type" => 6, "interlace" => 0,
               "filter" => "none", "compression_level" => 9, "strategy" => "default",
               "window_bits" => 15, "memory_level" => 8, "buffer_bytes" => 32_768 }.freeze

  module_function

  def manifest
    JSON.parse(File.read(File.join(ROOT, "manifest.json")))
  end

  def run(entry, environment = {})
    library = ENV.fetch("SVGPNG_TEST_NATIVE_LIBRARY", nil)
    environment = { "SVGPNG_TEST_NATIVE_LIBRARY" => library, "TZ" => "UTC", "LANG" => "C" }.merge(environment)
    output, errors, status = Open3.capture3(environment, RbConfig.ruby, "-I#{File.join(REPOSITORY, "lib")}",
                                            RUNNER, stdin_data: JSON.generate(entry), chdir: Dir.tmpdir)
    raise "Golden subprocess failed: #{errors}" unless status.success?

    JSON.parse(output)
  end

  def verify_inputs!(data) # rubocop:disable Metrics/AbcSize -- Audits each pinned input in one bounded pass.
    raise "Golden encoding profile changed" unless data.fetch("encoding") == ENCODING

    data.fetch("fixtures").each do |entry|
      verify_digest!(File.join(ROOT, entry.fetch("svg")), entry.fetch("svg_sha256"))
      verify_digest!(File.join(ROOT, entry.fetch("png")), entry.fetch("png_sha256")) if entry["png"]
    end
    data.fetch("fonts").each do |font|
      verify_digest!(File.join(FONT_ROOT, font.fetch("file")), font.fetch("sha256"))
    end
    nil
  end

  def verify_digest!(path, expected)
    raise "SHA-256 mismatch: #{path}" unless Digest::SHA256.file(path).hexdigest == expected
  end

  def chunks(bytes) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- Sequential PNG framing and CRC validation.
    raise "Invalid PNG signature" unless bytes.start_with?("\x89PNG\r\n\x1a\n".b)

    offset = 8
    result = []
    while offset < bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      type = bytes.byteslice(offset + 4, 4)
      payload = bytes.byteslice(offset + 8, length)
      crc = bytes.byteslice(offset + 8 + length, 4)&.unpack1("N")
      raise "Invalid PNG CRC" unless payload && crc == Zlib.crc32(type + payload)

      result << [type, payload]
      offset += length + 12
    end
    raise "Invalid PNG length" unless offset == bytes.bytesize

    result
  end
end
