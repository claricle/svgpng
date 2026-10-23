# frozen_string_literal: true

require "spec_helper"
require "svgpng/native"
require "zlib"

# Opt in with an isolated, explicitly built artifact; production loading stays unchanged.
if ENV["SVGPNG_TEST_NATIVE_LIBRARY"]
  RSpec.describe "real native rendering" do
    before do
      allow(Svgpng::Native).to receive(:packaged_library_path)
        .and_return(File.realpath(ENV.fetch("SVGPNG_TEST_NATIVE_LIBRARY")))
    end

    def render_svg(body = "", width: 2, height: 1, profile: {})
      source = %(<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}">#{body}</svg>)
      Svgpng.render(source, profile: profile, fonts: {}, fallback_fonts: [])
    end

    def png_chunks(bytes) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      expect(bytes.byteslice(0, 8)).to eq("\x89PNG\r\n\x1a\n".b)
      offset = 8
      chunks = []
      while offset < bytes.bytesize
        length = bytes.byteslice(offset, 4).unpack1("N")
        type = bytes.byteslice(offset + 4, 4)
        data = bytes.byteslice(offset + 8, length)
        expect(offset + length + 12).to be <= bytes.bytesize
        expect(bytes.byteslice(offset + 8 + length, 4).unpack1("N")).to eq(Zlib.crc32(type + data))
        chunks << [type, data]
        offset += length + 12
      end
      expect(offset).to eq(bytes.bytesize)
      chunks
    end

    def pixels(result) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      chunks = png_chunks(result.png_bytes)
      expect(chunks.map(&:first)).to match(["IHDR", *Array.new(chunks.length - 2, "IDAT"), "IEND"])
      expect(chunks.first.last.unpack("NNC5")).to eq([result.width, result.height, 8, 6, 0, 0, 0])
      expect(chunks.last.last).to eq("")
      payloads = chunks[1...-1].map(&:last)
      expect(payloads).not_to be_empty
      expect(payloads.map(&:bytesize)).to all(be <= 32_768)
      compressed = payloads.join
      expect(compressed.getbyte(0) & 0x0f).to eq(8) # Deflate; libpng may reduce the advertised window.
      expect(compressed.getbyte(1) & 0xe0).to eq(0xc0) # Maximum compression, no dictionary.
      raw = Zlib::Inflate.inflate(compressed)
      expect(raw.bytesize).to eq(((result.width * 4) + 1) * result.height)
      raw.bytes.each_slice((result.width * 4) + 1).map do |row|
        expect(row.shift).to eq(0) # Filter NONE, in top-to-bottom row order.
        row.each_slice(4).to_a
      end
    end

    it "renders opaque rows with the pinned PNG byte profile" do
      result = render_svg('<rect width="2" height="1" fill="red"/>' \
                          '<rect y="1" width="2" height="1" fill="blue"/>', height: 2)
      expect([result.width, result.height]).to eq([2, 2])
      expect(pixels(result)).to eq([[[255, 0, 0, 255]] * 2, [[0, 0, 255, 255]] * 2])
      expect(result.png_bytes).to be_frozen
      expect(result.warnings).to eq([])
      expect(result.font_manifest).to eq([])
    end

    it "centers a contained image over an opaque background" do
      profile = { width: 4, height: 4, background: "#0000ff" }
      result = render_svg('<rect width="4" height="2" fill="red"/>', width: 4, height: 2, profile: profile)
      red = [[255, 0, 0, 255]] * 4
      blue = [[0, 0, 255, 255]] * 4
      expect(pixels(result)).to eq([blue, red, red, blue])
    end

    it "scales the canvas and retains transparent pixels" do
      result = render_svg('<rect width="1" height="1" fill="red"/>', profile: { scale: "2" })
      expect([result.width, result.height]).to eq([4, 2])
      expect(pixels(result)).to eq([([[255, 0, 0, 255]] * 2) + ([[0, 0, 0, 0]] * 2)] * 2)
    end

    it "returns straight RGBA for translucent rendered pixels" do
      result = render_svg('<rect width="1" height="1" fill="red" fill-opacity="0.5"/>')
      expect(pixels(result)).to eq([[[255, 0, 0, 128], [0, 0, 0, 0]]])
    end

    it "preserves translucent background colors through the public pipeline" do
      result = render_svg(profile: { background: "#0000ff80" })
      expect(pixels(result)).to eq([[[0, 0, 255, 128]] * 2])
    end

    it "rejects external resources with the public typed error" do
      ['<image href="https://example.invalid/image.png"/>',
       '<image href="file:///tmp/image.png"/>',
       "<style>@import url(https://example.invalid/style.css);</style>"].each do |body|
        expect { render_svg(body) }.to raise_error(Svgpng::ForbiddenReferenceError)
      end
    end

    it "repeats the same complete PNG bytes deterministically" do
      source = '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1">' \
               '<rect width="1" height="1" fill="#123456"/></svg>'
      original = source.dup
      outputs = Array.new(4) do
        Svgpng.render(source, profile: { width: 4, height: 4 }, fonts: {}, fallback_fonts: []).png_bytes
      end
      expect(outputs.uniq.length).to eq(1)
      expect(source).to eq(original)
    end
  end
end
