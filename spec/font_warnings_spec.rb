# frozen_string_literal: true

require "svgpng/font_warnings"

RSpec.describe Svgpng::FontWarnings do
  def add(collector, **options)
    defaults = { requested: "Primary", selected: "Fallback", style: "normal", weight: 400,
                 stretch: "normal", scalars: [0x03B1] }
    values = defaults.merge(options)
    collector.add(requested_family: values.fetch(:requested), selected_family: values.fetch(:selected),
                  style: values.fetch(:style), weight: values.fetch(:weight),
                  stretch: values.fetch(:stretch), scalars: values.fetch(:scalars))
  end

  it "preserves first document-use order" do
    collector = described_class.new
    add(collector, requested: "First")
    add(collector, requested: "Second")

    expect(collector.warnings.map(&:requested_family)).to eq(%w[First Second])
  end

  it "deduplicates reordered scalar sets and stores a canonical scalar order" do
    collector = described_class.new
    add(collector, scalars: [0x03B2, 0x03B1, 0x03B2])
    add(collector, scalars: [0x03B1, 0x03B2])

    expect(collector.warnings.length).to eq(1)
    expect(collector.warnings.first.scalars).to eq([0x03B1, 0x03B2])
  end

  it "retains events for a different selected face or style" do
    collector = described_class.new
    add(collector)
    add(collector, selected: "Other")
    add(collector, style: "italic")

    expect(collector.warnings.map { |warning| [warning.selected_family, warning.style] })
      .to eq([%w[Fallback normal], %w[Other normal], %w[Fallback italic]])
  end

  it "returns frozen snapshots that do not alias future collector changes" do
    collector = described_class.new
    first = add(collector)
    snapshot = collector.warnings
    add(collector, requested: "Later")

    expect(snapshot).to eq([first])
    expect(snapshot).to be_frozen
    expect(first).to be_frozen
    expect(first.scalars).to be_frozen
    expect { snapshot.clear }.to raise_error(FrozenError)
  end

  it "copies mutable caller strings into the warning value" do
    collector = described_class.new
    requested = +"Primary"
    selected = +"Fallback"
    add(collector, requested: requested, selected: selected)
    requested.clear
    selected.clear

    expect(collector.warnings.first.requested_family).to eq("Primary")
    expect(collector.warnings.first.selected_family).to eq("Fallback")
  end

  [nil, -1, 0x110000, 0xD800, 0xDFFF, "65"].each do |invalid_scalar|
    it "rejects invalid Unicode scalar #{invalid_scalar.inspect}" do
      expect { add(described_class.new, scalars: [invalid_scalar]) }
        .to raise_error(ArgumentError, /Unicode scalar values/)
    end
  end
end
