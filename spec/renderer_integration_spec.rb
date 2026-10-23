# frozen_string_literal: true

require "spec_helper"
require "svgpng/native"
require_relative "support/native_rendering_helpers"
require "zlib"

# Opt in with an isolated, explicitly built artifact; production loading stays unchanged.
if ENV["SVGPNG_TEST_NATIVE_LIBRARY"]
  RSpec.describe "real native rendering" do
    include NativeRenderingHelpers

    before do
      allow(Svgpng::Native).to receive(:packaged_library_path)
        .and_return(File.realpath(ENV.fetch("SVGPNG_TEST_NATIVE_LIBRARY")))
    end

    it "renders opaque rows with the pinned PNG byte profile" do
      result = render_svg('<rect width="2" height="1" fill="red"/>' \
                          '<rect y="1" width="2" height="1" fill="blue"/>', height: 2)
      expect([result.width, result.height]).to eq([2, 2])
      expect(pixels(result)).to eq([[[255, 0, 0, 255]] * 2, [[0, 0, 255, 255]] * 2])
      expect(result.png_bytes).to be_frozen
      expect(result.warnings).to eq([])
      expect(result.font_manifest).to eq([])
    end

    it "centers a contained image over an opaque background" do
      profile = { width: 4, height: 4, background: "#0000ff" }
      result = render_svg('<rect width="4" height="2" fill="red"/>', width: 4, height: 2, profile: profile)
      red = [[255, 0, 0, 255]] * 4
      blue = [[0, 0, 255, 255]] * 4
      expect(pixels(result)).to eq([blue, red, red, blue])
    end

    it "scales the canvas and retains transparent pixels" do
      result = render_svg('<rect width="1" height="1" fill="red"/>', profile: { scale: "2" })
      expect([result.width, result.height]).to eq([4, 2])
      expect(pixels(result)).to eq([([[255, 0, 0, 255]] * 2) + ([[0, 0, 0, 0]] * 2)] * 2)
    end

    it "returns straight RGBA for translucent rendered pixels" do
      result = render_svg('<rect width="1" height="1" fill="red" fill-opacity="0.5"/>')
      expect(pixels(result)).to eq([[[255, 0, 0, 128], [0, 0, 0, 0]]])
    end

    it "preserves translucent background colors through the public pipeline" do
      result = render_svg(profile: { background: "#0000ff80" })
      expect(pixels(result)).to eq([[[0, 0, 255, 128]] * 2])
    end

    it "rejects external resources with the public typed error" do
      ['<image href="https://example.invalid/image.png"/>',
       '<image href="file:///tmp/image.png"/>',
       "<style>@import url(https://example.invalid/style.css);</style>"].each do |body|
        expect { render_svg(body) }.to raise_error(Svgpng::ForbiddenReferenceError)
      end
    end

    it "reports structural reference details without copying host paths or URLs" do
      references = [
        ['<image href="https://example.invalid/private.png"/>', "network", "image@href"],
        ['<use href="file:///private/secret.svg#id"/>', "file", "use@href"],
        ['<image href="../private.png"/>', "relative", "image@href"],
        ['<image href="/private/secret.png"/>', "absolute", "image@href"],
        ["<style>rect{fill:url(file:///private/secret.svg#id)}</style>", "file", "style@url"],
        ['<style>@import "https://example.invalid/private.css";</style>', "css_import", "style@import"],
        ['<image href="data:image/svg+xml,%3Csvg%20href=%22file:///private/secret%22/%3E"/>', "file", "svg@href"]
      ]
      references.each do |body, reference_class, location|
        expect { render_svg(body) }.to raise_error(Svgpng::ForbiddenReferenceError) do |error|
          expect([error.reference_class, error.location]).to eq([reference_class, location])
          expect(error.message).not_to include("private", "secret", "example.invalid")
          expect(error.reference_class).to be_frozen
          expect(error.location).to be_frozen
        end
      end
      source = '<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg"/>'
      expect { Svgpng.render(source, profile: {}, fonts: {}, fallback_fonts: []) }
        .to raise_error(Svgpng::ForbiddenReferenceError) { |error|
          expect([error.reference_class, error.location]).to eq(["doctype", "document@doctype"])
        }
    end

    it "distinguishes malformed references from parser depth limits and recovers" do
      expect { render_svg('<image href="data:image/png;base64,!"/>') }.to raise_error(Svgpng::InputError)
      nested = "#{"f(" * 130}url(#safe)#{")" * 130}"
      expect { render_svg(%(<rect style="fill:#{nested}"/>)) }.to raise_error(Svgpng::LimitError)
      expect(pixels(render_svg)).to eq([[[0, 0, 0, 0]] * 2])
    end

    it "renders the maximum supported canvas dimension" do
      result = render_svg('<rect width="32768" height="1" fill="#123456"/>', width: 32_768)
      expect([result.width, result.height]).to eq([32_768, 1])
      expect(pixels(result)).to eq([[[18, 52, 86, 255]] * 32_768])
      expect(result.warnings).to eq([])
      expect(result.font_manifest).to eq([])
    end

    it "rejects oversized canvas requests and leaves subsequent renders usable" do
      [{ width: 32_769 }, { width: 8001, height: 8000 }, { scale: "32769" }].each do |profile|
        expect { render_svg(profile: profile) }.to raise_error(Svgpng::LimitError)
      end
      expect { render_svg(width: 32_769) }.to raise_error(Svgpng::LimitError)
      expect(pixels(render_svg('<rect width="2" height="1" fill="red"/>'))).to eq([[[255, 0, 0, 255]] * 2])
    end

    it "enforces canvas bounds in the native ABI before returning a pixel buffer" do
      library = Svgpng::Native.load
      fonts = Svgpng::FontInputs.new(fonts: {}, fallback_fonts: [])
      [[32_769, 1], [8001, 8000]].each do |width, height|
        layout = Svgpng::RenderProfile.new.resolve({ "width" => "2", "height" => "1" }).dup
        layout.width = width
        layout.height = height
        expect { library.render_pixels('<svg xmlns="http://www.w3.org/2000/svg"/>', layout: layout, fonts: fonts) }
          .to raise_error(Svgpng::LimitError)
      end
      expect(pixels(render_svg)).to eq([[[0, 0, 0, 0]] * 2])
    end

    it "repeats the same complete PNG bytes deterministically" do
      source = '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1">' \
               '<rect width="1" height="1" fill="#123456"/></svg>'
      original = source.dup
      outputs = Array.new(4) do
        Svgpng.render(source, profile: { width: 4, height: 4 }, fonts: {}, fallback_fonts: []).png_bytes
      end
      expect(outputs.uniq.length).to eq(1)
      expect(source).to eq(original)
    end
  end
end
