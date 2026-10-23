# frozen_string_literal: true

require "spec_helper"
require "svgpng"

RSpec.describe Svgpng::RenderProfile do
  let(:attributes) { { "viewBox" => "0 0 20 10" } }

  it "uses the default viewport without dimensions or a viewBox" do
    layout = described_class.new.resolve({})
    expect([layout.width, layout.height]).to eq([300, 150])
    expect(layout.transform).to eq([1, 0, 0, 1, 0, 0])
  end

  it "uses a positive viewBox when neither root dimension is present" do
    layout = described_class.new.resolve(attributes)
    expect([layout.width, layout.height]).to eq([20, 10])
  end

  it "derives a missing root dimension from the viewBox" do
    layout = described_class.new.resolve(attributes.merge("width" => "200"))
    expect([layout.width, layout.height]).to eq([200, 100])
    layout = described_class.new.resolve(attributes.merge("height" => "200"))
    expect([layout.width, layout.height]).to eq([400, 200])
  end

  it "uses default dimensions for a missing axis without a usable viewBox" do
    width_only = described_class.new.resolve("width" => "200")
    height_only = described_class.new.resolve("height" => "200", "viewBox" => "0 0 0 20")
    expect([width_only.width, width_only.height]).to eq([200, 150])
    expect([height_only.width, height_only.height]).to eq([300, 200])
  end

  it "gives two root dimensions precedence over the viewBox ratio" do
    layout = described_class.new.resolve(attributes.merge("width" => "120", "height" => "80"))
    expect([layout.width, layout.height]).to eq([120, 80])
  end

  it "resolves physical lengths at 96 dpi and percentages against 300 by 150" do
    ["1in", "2.54cm", "25.4mm", "101.6q", "72pt", "6pc", "96px"].each do |length|
      layout = described_class.new.resolve("width" => length, "height" => "50%")
      expect([layout.intrinsic_width, layout.intrinsic_height]).to eq([96, 75])
    end
    layout = described_class.new.resolve("width" => "50%", "height" => "100%")
    expect([layout.width, layout.height]).to eq([150, 150])
  end

  it "derives output width and height independently from one requested axis" do
    wide = described_class.new(width: 100).resolve(attributes)
    tall = described_class.new(height: 100).resolve(attributes)
    expect([wide.width, wide.height]).to eq([100, 50])
    expect([tall.width, tall.height]).to eq([200, 100])
  end

  it "multiplies both intrinsic axes by an exact decimal scale" do
    layout = described_class.new(scale: "0.125").resolve(attributes)
    expect([layout.width, layout.height]).to eq([3, 1])
    expect(layout.intrinsic_width).to eq(Rational(20))
    expect(layout.scale).to eq(Rational(1, 10))
  end

  it "rounds half pixels up and clamps positive subpixel results to one" do
    half = described_class.new(width: 5).resolve(attributes)
    tiny = described_class.new(scale: "0.001").resolve(attributes)
    expect([half.width, half.height]).to eq([5, 3])
    expect([tiny.width, tiny.height]).to eq([1, 1])
  end

  it "fits and centers the intrinsic viewport in an exact canvas" do
    layout = described_class.new(width: 100, height: 100, background: "#80402080").resolve(attributes)
    expect([layout.width, layout.height]).to eq([100, 100])
    expect(layout.transform).to eq([5, 0, 0, 5, 0, 25])
    expect(layout.background).to eq([64, 32, 16, 128])
    portrait = described_class.new(width: 100, height: 100).resolve("viewBox" => "0 0 10 20")
    expect(portrait.transform).to eq([5, 0, 0, 5, 25, 0])
  end

  it "defaults to transparent black and premultiplies explicit backgrounds" do
    expect(described_class.new.resolve.background).to eq([0, 0, 0, 0])
    expect(described_class.new(background: "transparent").resolve.background).to eq([0, 0, 0, 0])
    expect(described_class.new(background: "#ff8020").resolve.background).to eq([255, 128, 32, 255])
    expect(described_class.new(background: "#ffffff00").resolve.background).to eq([0, 0, 0, 0])
    expect(described_class.new(background: "#ffffff01").resolve.background).to eq([1, 1, 1, 1])
  end

  it "returns immutable layouts and captures mutable profile input" do
    background = +"#80402080"
    scale = +"2"
    profile = described_class.new(background: background, scale: scale)
    background.replace("transparent")
    scale.replace("3")
    layout = profile.resolve(attributes)
    expect([layout.width, layout.height]).to eq([40, 20])
    expect(layout.background).to eq([64, 32, 16, 128])
    expect(profile).to be_frozen
    expect(layout).to be_frozen
    expect(layout.background).to be_frozen
    expect(layout.transform).to be_frozen
    expect([layout.stride, layout.buffer_bytes]).to eq([160, 3200])
  end

  it "rejects invalid profile shapes and every unknown or string key" do
    [nil, [], true, { "width" => 10 }, { unknown: 1 }].each do |profile|
      expect { described_class.new(profile) }.to raise_error(Svgpng::ProfileError)
    end
  end

  it "rejects invalid pixel dimensions on either axis" do
    [nil, true, false, 0, -1, 1.5, "20", Float::NAN, Float::INFINITY].each do |value|
      %i[width height].each do |axis|
        expect { described_class.new(axis => value) }.to raise_error(Svgpng::ProfileError)
      end
    end
  end

  it "rejects invalid scales and combinations with dimensions" do
    [nil, true, 1, 1.5, "", "0", "-1", "NaN", "Infinity", "1/2", "1e2", " 2 "].each do |value|
      expect { described_class.new(scale: value) }.to raise_error(Svgpng::ProfileError)
    end
    %i[width height].each do |axis|
      expect { described_class.new(axis => 10, scale: "2") }.to raise_error(Svgpng::ProfileError)
    end
  end

  it "rejects unsupported background formats" do
    [nil, true, "red", "#fff", "#1234567", "#zz1122", "rgb(0,0,0)", "Transparent"].each do |value|
      expect { described_class.new(background: value) }.to raise_error(Svgpng::ProfileError)
    end
  end

  it "rejects unsupported relative, nonpositive, and nonfinite root dimensions" do
    ["1em", "1rem", "1ex", "calc(10px)", "0", "-2", "NaN", "Infinity", "100vw", "", "1e309"].each do |value|
      %w[width height].each do |axis|
        expect { described_class.new.resolve(axis => value) }.to raise_error(Svgpng::ProfileError)
      end
    end
    expect { described_class.new.resolve(width: "20") }.to raise_error(Svgpng::ProfileError)
  end

  it "rejects malformed viewBoxes and preserves default behavior for nonpositive extents" do
    ["0 0 20", "0 0 20 10 5", "0 0 NaN 10", "0 0 Infinity 10", "0 0 20px 10",
     "0,,0,20,10", "0 0 1e309 10"].each do |value|
      expect { described_class.new.resolve("viewBox" => value) }.to raise_error(Svgpng::ProfileError)
    end
    ["0 0 0 10", "0 0 20 -1"].each do |value|
      layout = described_class.new.resolve("viewBox" => value)
      expect([layout.width, layout.height]).to eq([300, 150])
    end
  end

  it "bounds root numeric representations before rational construction while preserving tiny positive sizes" do
    ["1e999999999", "1e-999999999", "1" * 1025].each do |value|
      expect { described_class.new.resolve("width" => value) }.to raise_error(Svgpng::LimitError)
      expect { described_class.new.resolve("viewBox" => "0 0 #{value} 10") }.to raise_error(Svgpng::LimitError)
    end
    layout = described_class.new.resolve("width" => "1e-1000", "height" => "1e-1000")
    expect([layout.width, layout.height]).to eq([1, 1])
  end

  it "checks explicit and derived dimension and pixel limits before allocation" do
    expect { described_class.new(width: 32_769) }.to raise_error(Svgpng::LimitError)
    expect { described_class.new(height: 32_769) }.to raise_error(Svgpng::LimitError)
    expect { described_class.new(scale: "2000").resolve(attributes) }.to raise_error(Svgpng::LimitError)
    expect { described_class.new.resolve("width" => "32769", "height" => "1") }.to raise_error(Svgpng::LimitError)
    expect { described_class.new(width: 8001, height: 8000).resolve }.to raise_error(Svgpng::LimitError)
    layout = described_class.new(width: 8000, height: 8000).resolve
    expect([layout.width, layout.height, layout.buffer_bytes]).to eq([8000, 8000, 256_000_000])
    edge = described_class.new(width: 32_768, height: 1).resolve
    expect(edge.stride).to eq(131_072)
  end
end
