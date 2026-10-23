# frozen_string_literal: true

RSpec.describe Svgpng::FontInputs do
  let(:first) { Svgpng::FontFace.new(bytes: "first", source_id: "one") }
  let(:second) { Svgpng::FontFace.new(bytes: "second", source_id: "two") }

  it "copies family mappings and retains caller fallback order" do
    fonts = { "Primary" => first }
    fallback = [second, first]
    inputs = described_class.new(fonts: fonts, fallback_fonts: fallback)
    fonts.clear
    fallback.reverse!
    expect(inputs.fonts).to eq("Primary" => [first])
    expect(inputs.fallback_fonts).to eq([second, first])
    expect(inputs.fonts.values.first).to be_frozen
  end

  it "copies an optional fallback family assertion without changing source identity or byte digest" do
    family = +"Expected Family"
    face = Svgpng::FontFace.new(bytes: "first", source_id: "one", family: family)
    family.replace("Changed")
    expect(face.family).to eq("Expected Family")
    expect(face.family).to be_frozen
    expect([face.source_id, face.sha256]).to eq([first.source_id, first.sha256])
    expect(first.family).to be_nil
    ["", " ", 1, []].each do |invalid|
      expect { Svgpng::FontFace.new(bytes: "first", source_id: "one", family: invalid) }
        .to raise_error(Svgpng::InputError)
    end
  end

  it "rejects invalid container, family, empty-face and face shapes" do
    [nil, [], { "" => first }, { "Primary" => [] }, { "Primary" => "path.ttf" }].each do |fonts|
      expect { described_class.new(fonts: fonts, fallback_fonts: []) }.to raise_error(Svgpng::InputError)
    end
  end

  it "enforces face count and total byte limits" do
    stub_const("Svgpng::Limits::FONT_COUNT", 1)
    expect do
      described_class.new(fonts: { "Primary" => first }, fallback_fonts: [second])
    end.to raise_error(Svgpng::LimitError)
    stub_const("Svgpng::Limits::TOTAL_FONT_BYTES", 4)
    expect do
      described_class.new(fonts: { "Primary" => first }, fallback_fonts: [])
    end.to raise_error(Svgpng::LimitError)
  end
end
