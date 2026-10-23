# frozen_string_literal: true

RSpec.describe Svgpng do
  it "defers unsupported-platform failure until rendering" do
    expect(described_class::VERSION).to eq("0.1.0")
    expect do
      described_class.render("<svg/>", profile: {}, fonts: {}, fallback_fonts: [])
    end.to raise_error(Svgpng::UnsupportedPlatformError) { |error|
      expect(error.platform).to eq(Gem::Platform.local.to_s)
      expect(error.supported_targets).to include("arm64-darwin", "x64-mingw-ucrt")
      expect(error.supported_targets.length).to eq(7)
    }
  end

  it "accepts no external resource injection argument" do
    expect do
      described_class.render("<svg/>", profile: {}, fonts: {}, fallback_fonts: [], resources: {})
    end.to raise_error(ArgumentError, /unknown keyword/)
  end

  it "copies caller font bytes and diagnostic identity" do
    bytes = +"font bytes"
    source = +"caller-face"
    face = Svgpng::FontFace.new(bytes: bytes, source_id: source)
    bytes.clear
    source.clear
    expect(face.bytes).to eq("font bytes".b)
    expect(face.source_id).to eq("caller-face")
    expect(face.sha256).to eq(Digest::SHA256.hexdigest("font bytes"))
    expect(face).to be_frozen
    expect(face.bytes).to be_frozen
  end

  it "preserves ordered immutable warning and face diagnostics" do
    warning = Svgpng::FontSubstitutionWarning.new(requested_family: "Primary", selected_family: "Fallback",
                                                  style: "normal", weight: 400, stretch: "normal", scalars: [0x03B1])
    bytes = +"PNG"
    manifest = [{ source_id: +"caller", sha256: +"digest" }]
    result = Svgpng::Result.new(png_bytes: bytes, width: 2, height: 1,
                                warnings: [warning], font_manifest: manifest)
    bytes.clear
    manifest.first[:source_id].clear
    expect(result.png_bytes).to eq("PNG".b)
    expect([result.width, result.height]).to eq([2, 1])
    expect(result.warnings).to eq([warning])
    expect(result.font_manifest.first[:source_id]).to eq("caller")
    expect { result.warnings << warning }.to raise_error(FrozenError)
    expect { warning.scalars << 0 }.to raise_error(FrozenError)
  end
end
