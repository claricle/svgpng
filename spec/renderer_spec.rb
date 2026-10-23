# frozen_string_literal: true

require "spec_helper"
require "svgpng/native"

RSpec.describe Svgpng::Renderer do
  let(:library) { instance_double(Svgpng::Native::Library) }
  let(:source) { '<svg width="2" height="1"/>' }
  let(:pixels) { "\xff".b * 8 }
  let(:warning) do
    { "requested_family" => "Primary", "selected_family" => "Fallback", "style" => "normal",
      "weight" => 400, "stretch" => "normal", "scalars" => [945] }
  end

  before { allow(Svgpng::Native).to receive(:load).and_return(library) }

  it "resolves native root geometry then renders, converts and encodes into an immutable result" do
    expect(library).to receive(:root_attributes).with(source).ordered.and_return("width" => "2", "height" => "1")
    expect(library).to receive(:render_pixels).ordered do |svg, layout:, fonts:|
      expect(svg).to eq(source)
      expect(svg).to be_frozen
      expect([layout.width, layout.height]).to eq([4, 2])
      expect(layout.scale).to eq(2)
      expect(fonts.fonts).to eq({})
      [pixels, { "warnings" => [warning, warning], "font_manifest" => [{ "source_id" => "face" }] }]
    end
    expect(library).to receive(:rgba_to_straight).with(pixels, width: 4, height: 2).ordered.and_return("straight")
    expect(library).to receive(:encode_rgba).with("straight", width: 4, height: 2).ordered.and_return("PNG")
    result = described_class.render(source, profile: { scale: "2" }, fonts: {}, fallback_fonts: [])
    expect([result.png_bytes, result.width, result.height]).to eq(["PNG", 4, 2])
    expect(result.warnings.length).to eq(1)
    expect(result.warnings.first.scalars).to eq([945])
    expect(result.font_manifest).to eq([{ "source_id" => "face" }])
    expect(result).to be_frozen
  end

  it "rejects unsafe XML and invalid profiles before invoking any native parser" do
    expect(library).not_to receive(:root_attributes)
    expect do
      described_class.render("<!DOCTYPE svg><svg/>", profile: {}, fonts: {}, fallback_fonts: [])
    end.to raise_error(Svgpng::ForbiddenReferenceError)
    expect do
      described_class.render(source, profile: { scale: "2", width: 1 }, fonts: {}, fallback_fonts: [])
    end.to raise_error(Svgpng::ProfileError)
  end
end
