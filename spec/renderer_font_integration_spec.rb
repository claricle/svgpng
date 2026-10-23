# frozen_string_literal: true

require "spec_helper"
require "svgpng/native"
require_relative "support/native_font_rendering_helpers"

# Explicit opt-in exercises the real artifact and supplied, licensed font fixtures.
if ENV["SVGPNG_TEST_NATIVE_LIBRARY"]
  RSpec.describe "real native font rendering" do
    include NativeFontRenderingHelpers

    let(:font_directory) { File.expand_path("../native/svgpng_renderer/tests/fonts", __dir__) }
    let(:regular) { font_face("NotoSans-Regular.ttf", "noto-regular") }
    let(:bold) { font_face("NotoSans-Bold.ttf", "noto-bold") }
    let(:devanagari) { font_face("NotoSansDevanagari-Regular.ttf", "noto-devanagari") }
    let(:cluster_scalars) { [0x0915, 0x0937, 0x093f, 0x094d] }

    before do
      allow(Svgpng::Native).to receive(:packaged_library_path)
        .and_return(File.realpath(ENV.fetch("SVGPNG_TEST_NATIVE_LIBRARY")))
    end

    it "records the actual selected face metadata and produces visible text" do
      result = render_text("office", fonts: { "Noto Sans" => [regular, bold] })
      blank = render_body("")
      expect([result.width, result.height]).to eq([120, 40])
      expect(result.png_bytes).not_to eq(blank.png_bytes)
      expect(result.font_manifest).to eq([metadata(regular, family: "noto sans")])
      expect(result.font_manifest.first).to be_frozen
      expect(result.warnings).to eq([])
    end

    it "validates an explicit fallback family against parsed metadata without changing selection diagnostics" do
      matched = Svgpng::FontFace.new(bytes: regular.bytes, source_id: regular.source_id, family: "Noto Sans")
      mismatched = Svgpng::FontFace.new(bytes: regular.bytes, source_id: regular.source_id, family: "Absent")
      expected = render_text("A", family: "Absent", fallback_fonts: [regular])
      result = render_text("A", family: "Absent", fallback_fonts: [matched])
      expect(result.png_bytes).to eq(expected.png_bytes)
      expect(result.font_manifest).to eq(expected.font_manifest)
      expect(result.warnings.map { |warning| warning_fields(warning) })
        .to eq(expected.warnings.map { |warning| warning_fields(warning) })
      expect { render_text("A", family: "Absent", fallback_fonts: [mismatched]) }
        .to raise_error(Svgpng::FontMetadataError)
    end

    it "selects the requested weight using supplied face metadata" do
      exact = render_text("A", weight: 700, fonts: { "Noto Sans" => [regular, bold] })
      fallback = render_text("A", family: "Absent", weight: 700, fallback_fonts: [regular, bold])
      expect(exact.font_manifest).to eq([metadata(bold, family: "noto sans", weight: 700)])
      expect(fallback.font_manifest).to eq(exact.font_manifest)
      expect(fallback.png_bytes).to eq(exact.png_bytes)
      expect(fallback.warnings.map { |warning| warning_fields(warning) })
        .to eq([["Absent", "noto sans", "normal", 700, "normal", [65]]])
    end

    it "honors caller fallback family order when both faces cover the cluster" do
      orders = [[regular, "Noto Sans", devanagari], [devanagari, "Noto Sans Devanagari", regular]]
      orders.each do |first, family, second|
        fallback = render_text("A", family: "Absent", fallback_fonts: [first, second])
        direct = render_text("A", family: family, fonts: { family => first })
        expect(fallback.png_bytes).to eq(direct.png_bytes)
        expect(fallback.font_manifest).to eq([metadata(first, family: family.downcase)])
        expect(fallback.warnings.map { |warning| warning_fields(warning) })
          .to eq([["Absent", family.downcase, "normal", 400, "normal", [65]]])
      end
    end

    it "reports missing family and the first uncovered shaped cluster through typed public errors" do
      expect { render_text("A", family: "Absent", fonts: { "Noto Sans" => regular }) }
        .to raise_error(Svgpng::MissingFamilyError) { |error| expect(error.requested_family).to eq("Absent") }
      expect { render_text("क्षि", fonts: { "Noto Sans" => regular }) }
        .to raise_error(Svgpng::MissingGlyphError) { |error|
          expect(error.requested_family).to eq("Noto Sans")
          # Without a covering face, Noto Sans shapes this conjunct as क् followed by षि.
          expect(error.scalars).to eq([0x0915, 0x094d])
          expect(error.scalars).to be_frozen
        }
    end

    it "shapes a whole fallback cluster identically to its exact-family control" do
      fallback = render_text("क्षि", fonts: { "Noto Sans" => regular }, fallback_fonts: [devanagari])
      direct = render_text("क्षि", family: "Noto Sans Devanagari", fonts: { "Noto Sans Devanagari" => devanagari })
      expect(fallback.png_bytes).to eq(direct.png_bytes)
      expect(fallback.font_manifest).to eq([metadata(devanagari, family: "noto sans devanagari")])
      expect(fallback.warnings.map { |warning| warning_fields(warning) })
        .to eq([["Noto Sans", "noto sans devanagari", "normal", 400, "normal", cluster_scalars]])
      expect(fallback.warnings.first).to be_frozen
      expect(fallback.warnings.first.scalars).to be_frozen
    end

    it "orders substitutions by first document use and deduplicates repeated clusters" do
      body = '<text font-family="Absent" x="2" y="30">क्षि</text>' \
             '<text font-family="Absent" x="40" y="30">A</text>' \
             '<text font-family="Absent" x="60" y="30">क्षि</text>'
      result = render_body(body, fallback_fonts: [regular, devanagari])
      expected_warnings = [
        ["Absent", "noto sans devanagari", "normal", 400, "normal", cluster_scalars],
        ["Absent", "noto sans", "normal", 400, "normal", [65]]
      ]
      expect(result.warnings.map { |warning| warning_fields(warning) }).to eq(expected_warnings)
      expected_manifest = [metadata(regular, family: "noto sans"),
                           metadata(devanagari, family: "noto sans devanagari")]
      expect(result.font_manifest).to eq(expected_manifest)
    end

    it "repeats PNG bytes, selected metadata and warnings across renders" do
      outputs = Array.new(3) do
        result = render_text("क्षि", fonts: { "Noto Sans" => regular }, fallback_fonts: [devanagari])
        [result.png_bytes, result.font_manifest, result.warnings.map { |warning| warning_fields(warning) }]
      end
      expect(outputs.uniq.length).to eq(1)
    end
  end
end
