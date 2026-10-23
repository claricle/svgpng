# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/golden_corpus"

RSpec.describe "committed renderer goldens" do
  let(:manifest) { GoldenCorpus.manifest }

  it "pins every SVG, font, PNG and encoding input" do
    expect { GoldenCorpus.verify_inputs!(manifest) }.not_to raise_error
  end

  it "matches every committed byte and diagnostic in clean processes" do
    if !ENV["SVGPNG_TEST_NATIVE_LIBRARY"] && ENV["SVGPNG_REQUIRE_GOLDENS"] != "1"
      skip "set SVGPNG_TEST_NATIVE_LIBRARY for real-artifact golden verification"
    end
    manifest.fetch("fixtures").each do |entry|
      first = GoldenCorpus.run(entry)
      second = GoldenCorpus.run(entry, "TZ" => "Pacific/Auckland", "LANG" => "C.UTF-8", "HOME" => Dir.tmpdir)
      expect(second).to eq(first), entry.fetch("svg")
      if entry["error"]
        expect(first).to eq(entry.fetch("expected"))
        next
      end
      expect(first.except("png")).to eq(entry.fetch("expected"))
      bytes = first.fetch("png").unpack1("m0")
      expect(bytes).to eq(File.binread(File.join(GoldenCorpus::ROOT, entry.fetch("png"))))
      chunks = GoldenCorpus.chunks(bytes)
      expect(chunks.map(&:first)).to match(["IHDR", *Array.new(chunks.length - 2, "IDAT"), "IEND"])
      expect(chunks.first.last.unpack("NNCCCCC")).to eq([first.fetch("width"), first.fetch("height"), 8, 6, 0, 0, 0])
      expect(chunks.filter_map { |type, payload| payload.bytesize if type == "IDAT" }).to all(be <= 32_768)
      rows = Zlib::Inflate.inflate(chunks.filter_map { |type, payload| payload if type == "IDAT" }.join)
      stride = (first.fetch("width") * 4) + 1
      expect(rows.bytesize).to eq(stride * first.fetch("height"))
      expect((0...first.fetch("height")).map { |row| rows.getbyte(row * stride) }.uniq).to eq([0])
    end
  end

  it "preserves golden bytes and diagnostics during concurrent renders" do
    if !ENV["SVGPNG_TEST_NATIVE_LIBRARY"] && ENV["SVGPNG_REQUIRE_GOLDENS"] != "1"
      skip "set SVGPNG_TEST_NATIVE_LIBRARY for real-artifact golden verification"
    end
    manifest.fetch("fixtures").each do |entry|
      results = GoldenCorpus.run(entry.merge("concurrency" => 4))
      expect(results.length).to eq(4)
      expected = entry.fetch("expected").dup
      expected["png"] = [File.binread(File.join(GoldenCorpus::ROOT, entry.fetch("png")))].pack("m0") if entry["png"]
      expect(results).to all(eq(expected)), entry.fetch("svg")
    end
  end
end
