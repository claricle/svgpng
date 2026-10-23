# frozen_string_literal: true

# Helpers scoped explicitly to the real-artifact integration examples.
module NativeRenderingHelpers
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
end
