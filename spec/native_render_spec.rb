# frozen_string_literal: true

require "spec_helper"
require "svgpng/native"
require "tmpdir"
require "open3"
require "rbconfig"

RSpec.describe Svgpng::Native::RenderBinding do
  before(:context) do
    @directory = File.realpath(Dir.mktmpdir("svgpng-render-binding"))
    @path = File.join(@directory, "renderer.#{RbConfig::CONFIG["DLEXT"]}")
    source = File.join(@directory, "fixture.c")
    File.write(source, <<~'C')
      #include <stdint.h>
      #include <stdlib.h>
      #include <string.h>
      typedef struct { uint8_t *pixels; size_t pixels_length; uint8_t *diagnostics; size_t diagnostics_length; } Out;
      typedef struct { const uint8_t *bytes; size_t length; const uint8_t *family; size_t family_length;
        const uint8_t *source; size_t source_length; size_t fallback; } Font;
      typedef struct { uint32_t abi, width, height, background; double iw, ih, fit, tx, ty; } Opt;
      static int mode, releases;
      static char error_json[8192];
      void fixture_diagnostics(const char *text) {
        strncpy(error_json, text, sizeof(error_json) - 1); error_json[sizeof(error_json) - 1] = 0;
      }
      void fixture_mode(int value) { mode = value; releases = 0; error_json[0] = 0; }
      int fixture_releases(void) { return releases; }
      static void diagnostics(Out *out, const char *text) {
        out->diagnostics_length = strlen(text); out->diagnostics = malloc(strlen(text));
        memcpy(out->diagnostics, text, strlen(text));
      }
      int svgpng_v1_root_attributes(const uint8_t *svg, size_t length, Out *out) {
        if (!svg || length == 0 || out->pixels || out->diagnostics) return 8;
        diagnostics(out, error_json[0] ? error_json : "{\"width\":\"2\",\"height\":\"1\"}"); return mode;
      }
      int svgpng_v1_render(const uint8_t *svg, size_t length, const Font *fonts, size_t count,
          const Opt *options, Out *out) {
        if (!svg || length == 0 || options->abi != 1 || options->width != 2 || options->height != 1 ||
            options->iw != 2.0 || options->ih != 1.0 || options->fit != 1.0 || options->tx != 0.0 ||
            options->ty != 0.0 || options->background != 0xff0000ff || count != 2 ||
            fonts[0].length != 4 || memcmp(fonts[0].bytes, "face", 4) || fonts[0].family_length != 4 ||
            memcmp(fonts[0].family, "Test", 4) || fonts[0].source_length != 4 ||
            memcmp(fonts[0].source, "face", 4) || fonts[0].fallback != SIZE_MAX ||
            fonts[1].family_length != 0 || fonts[1].fallback != 0) return 8;
        out->pixels = malloc(8); out->pixels_length = 8; memset(out->pixels, 255, 8);
        diagnostics(out, "{\"warnings\":[],\"font_manifest\":[{\"source_id\":\"face\"}]}");
        if (error_json[0]) { free(out->diagnostics); diagnostics(out, error_json); }
        if (mode == 45) { out->diagnostics_length = 4194305; return 5; }
        if (mode == 20) out->pixels_length = 7;
        if (mode == 21) out->diagnostics_length = 4194305;
        if (mode == 22) out->diagnostics[0] = '!';
        return mode >= 20 && mode <= 22 ? 0 : mode;
      }
      void svgpng_v1_render_free(Out *out) {
        releases++; free(out->pixels); free(out->diagnostics); memset(out, 0, sizeof(*out));
      }
    C
    shared = RUBY_PLATFORM.include?("darwin") ? "-dynamiclib" : "-shared"
    rgba = File.expand_path("../native/svgpng_shim/rgba.c", __dir__)
    output, status = Open3.capture2e("cc", shared, "-fPIC", "-Wall", "-Wextra", "-Werror",
                                     source, rgba, "-o", @path)
    raise output unless status.success?
  end

  after(:context) { FileUtils.remove_entry(@directory) }

  let(:library) { Svgpng::Native.load }
  let(:handle) { Fiddle::Handle.new(@path) }
  let(:set_mode) { Fiddle::Function.new(handle["fixture_mode"], [Fiddle::TYPE_INT], Fiddle::TYPE_VOID) }
  let(:set_diagnostics) do
    Fiddle::Function.new(handle["fixture_diagnostics"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
  end
  let(:releases) { Fiddle::Function.new(handle["fixture_releases"], [], Fiddle::TYPE_INT) }
  let(:layout) { Svgpng::RenderProfile.new(background: "#ff0000").resolve("width" => "2", "height" => "1") }
  let(:face) { Svgpng::FontFace.new(bytes: "face", source_id: "face") }
  let(:fonts) { Svgpng::FontInputs.new(fonts: { "Test" => [face] }, fallback_fonts: [face]) }

  before do
    allow(Svgpng::Native).to receive(:packaged_library_path).and_return(@path)
    set_mode.call(0)
  end

  it "copies parser attributes and releases the descriptor before returning" do
    expect(library.root_attributes("<svg/>")).to eq("width" => "2", "height" => "1")
    expect(releases.call).to eq(1)
  end

  it "passes aligned options and ordered owned fonts and copies both outputs" do
    pixels, diagnostics = library.render_pixels("<svg/>", layout: layout, fonts: fonts)
    expect(pixels).to eq("\xff".b * 8)
    expect(diagnostics).to eq("warnings" => [], "font_manifest" => [{ "source_id" => "face" }])
    expect(releases.call).to eq(1)
    expect(face.bytes).to eq("face")
  end

  it "maps every native failure and releases allocated outputs on failures" do
    described_class::ERRORS.merge(99 => Svgpng::NativeError).each do |status, error|
      set_mode.call(status)
      expect { library.render_pixels("<svg/>", layout: layout, fonts: fonts) }.to raise_error(error)
      expect(releases.call).to eq(1)
    end
  end

  it "rejects wrong pixel sizes, oversized diagnostics and malformed JSON before exposing results" do
    { 20 => Svgpng::NativeError, 21 => Svgpng::LimitError, 22 => Svgpng::NativeError }.each do |mode, error|
      set_mode.call(mode)
      expect { library.render_pixels("<svg/>", layout: layout, fonts: fonts) }.to raise_error(error)
      expect(releases.call).to eq(1)
    end
  end

  def native_failure(status, detail)
    set_mode.call(status)
    set_diagnostics.call(JSON.generate("error" => detail))
    yield
  end

  it "copies immutable family and Unicode scalar details without native prose" do
    detail = { "requested_family" => "Primary", "scalars" => [945, 65, 945], "message" => "/secret/host/font" }
    native_failure(6, detail) do
      expect { library.render_pixels("<svg/>", layout: layout, fonts: fonts) }
        .to raise_error(Svgpng::MissingGlyphError) { |error|
          expect(error.requested_family).to eq("Primary")
          expect(error.scalars).to eq([65, 945])
          expect(error.requested_family).to be_frozen
          expect(error.scalars).to be_frozen
          expect(error.message).to eq("SVGPNG rendering failed (status 6)")
        }
    end
    expect(releases.call).to eq(1)
  end

  it "accepts Unicode scalar boundaries while excluding surrogate values" do
    scalars = [0, 0xD7FF, 0xE000, 0x10FFFF]
    native_failure(6, "scalars" => scalars) do
      expect { library.render_pixels("<svg/>", layout: layout, fonts: fonts) }
        .to raise_error(Svgpng::MissingGlyphError) { |error| expect(error.scalars).to eq(scalars) }
    end
    expect(releases.call).to eq(1)
  end

  it "maps family details on root errors and releases diagnostics" do
    native_failure(5, "requested_family" => "Primary") do
      expect { library.root_attributes("<svg/>") }.to raise_error(Svgpng::MissingFamilyError) { |error|
        expect(error.requested_family).to eq("Primary")
      }
    end
    expect(releases.call).to eq(1)
  end

  it "exposes only approved reference classes and structural locations" do
    native_failure(7, "reference_class" => "network", "location" => "image@href", "uri" => "https://secret") do
      expect { library.root_attributes("<svg/>") }.to raise_error(Svgpng::ForbiddenReferenceError) { |error|
        expect(error.reference_class).to eq("network")
        expect(error.location).to eq("image@href")
        expect(error.reference_class).to be_frozen
        expect(error.location).to be_frozen
        expect(error.message).not_to include("secret")
      }
    end
    expect(releases.call).to eq(1)
  end

  it "discards malformed optional family and scalar fields" do
    [nil, [], { "requested_family" => "bad\nfamily", "scalars" => [0xD800] },
     { "requested_family" => "x" * 1025, "scalars" => [0x110000] },
     { "requested_family" => 1, "scalars" => ["U+0041"] },
     { "scalars" => [-1] }, { "scalars" => [65.0] },
     { "scalars" => [65] * 257 }].each do |detail|
      native_failure(6, detail) do
        expect { library.render_pixels("<svg/>", layout: layout, fonts: fonts) }
          .to raise_error(Svgpng::MissingGlyphError) { |error|
            expect(error.requested_family).to be_nil
            expect(error.scalars).to be_nil
          }
      end
      expect(releases.call).to eq(1)
    end
  end

  it "discards reference values that could reveal host content" do
    native_failure(7, "reference_class" => "file:///secret", "location" => "/Users/private/font.svg") do
      expect { library.root_attributes("<svg/>") }.to raise_error(Svgpng::ForbiddenReferenceError) { |error|
        expect(error.reference_class).to be_nil
        expect(error.location).to be_nil
        expect(error.message).to eq("SVGPNG rendering failed (status 7)")
      }
    end
  end

  it "preserves status classification for malformed or oversized error diagnostics" do
    set_mode.call(5)
    set_diagnostics.call("not JSON /secret/host")
    expect { library.root_attributes("<svg/>") }.to raise_error(Svgpng::MissingFamilyError) { |error|
      expect(error.requested_family).to be_nil
    }
    expect(releases.call).to eq(1)
    set_mode.call(45)
    expect { library.render_pixels("<svg/>", layout: layout, fonts: fonts) }
      .to raise_error(Svgpng::MissingFamilyError)
    expect(releases.call).to eq(1)
  end
end
