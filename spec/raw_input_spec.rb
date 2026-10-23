# frozen_string_literal: true

RSpec.describe Svgpng::RawInput do
  it "rejects declarations before any XML parser can expand entities" do
    ["<!DOCTYPE svg><svg/>", '<!DOCTYPE svg SYSTEM "file:///private/secret"><svg/>',
     '<!DOCTYPE svg [<!ENTITY a "expanded">]><svg>&a;</svg>'].each do |svg|
      expect { described_class.validate!(svg) }.to raise_error(Svgpng::ForbiddenReferenceError)
    end
  end

  it "ignores declaration text in comments, CDATA and processing instructions" do
    svg = "<svg><!-- α <!DOCTYPE svg> --><![CDATA[<!DOCTYPE svg>]]><?demo <!DOCTYPE svg>?></svg>"
    expect(described_class.validate!(svg)).to eq(svg)
    expect do
      described_class.validate!("<!--α safe--><!DOCTYPE svg><svg/>")
    end.to raise_error(Svgpng::ForbiddenReferenceError)
  end

  it "rejects unterminated lexical tokens and invalid byte encodings" do
    ["<!--open", "<![CDATA[open", "<?open", "\xff".b, "<\0s\0v\0g\0>\0".b].each do |svg|
      expect { described_class.validate!(svg) }.to raise_error(Svgpng::InputError)
    end
  end

  it "checks the SVG byte bound and returns an immutable copy" do
    stub_const("Svgpng::Limits::SVG_BYTES", 6)
    svg = +"<svg/>"
    validated = described_class.validate!(svg)
    svg.clear
    expect(validated).to eq("<svg/>")
    expect(validated).to be_frozen
    expect { described_class.validate!("<svg/> ") }.to raise_error(Svgpng::LimitError)
  end

  it "checks actual bytes when a String subclass overrides inspection" do
    stub_const("Svgpng::Limits::SVG_BYTES", 6)
    misleading = Class.new(String) do
      def bytesize = 0
      def dup = "<svg/>"
    end

    expect { described_class.validate!(misleading.new("<svg/> ")) }.to raise_error(Svgpng::LimitError)
    expect do
      described_class.validate!(misleading.new("\xff".b))
    end.to raise_error(Svgpng::InputError)
    expect(described_class.validate!(misleading.new("<svg/>"))).to be_instance_of(String)
  end
end
