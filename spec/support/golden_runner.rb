# frozen_string_literal: true

# Test-only subprocess entry point. Production loading has no environment override.
require "json"
require "svgpng"
require "svgpng/native"

if ENV["SVGPNG_TEST_NATIVE_LIBRARY"]
  library = File.realpath(ENV.fetch("SVGPNG_TEST_NATIVE_LIBRARY"))
  Svgpng::Native.define_singleton_method(:packaged_library_path) { library }
end

request = JSON.parse($stdin.read)
root = File.expand_path("../fixtures/svg_to_png", __dir__)
font_root = File.expand_path("../../native/svgpng_renderer/tests/fonts", __dir__)
make_face = lambda do |filename|
  Svgpng::FontFace.new(bytes: File.binread(File.join(font_root, filename)), source_id: filename)
end
fonts = request.fetch("fonts", {}).transform_values { |files| files.map { |file| make_face.call(file) } }
fallback = request.fetch("fallback_fonts", []).map { |file| make_face.call(file) }
begin
  result = Svgpng.render(File.binread(File.join(root, request.fetch("svg"))),
                         profile: request.fetch("profile").transform_keys(&:to_sym),
                         fonts: fonts, fallback_fonts: fallback)
  warnings = result.warnings.map do |warning|
    %i[requested_family selected_family style weight stretch scalars].to_h do |field|
      [field, warning.public_send(field)]
    end
  end
  puts JSON.generate(png: [result.png_bytes].pack("m0"), width: result.width,
                     height: result.height, warnings: warnings, font_manifest: result.font_manifest)
rescue Svgpng::Error => e
  details = %i[requested_family scalars reference_class location].filter_map do |field|
    [field, e.public_send(field)] if e.respond_to?(field)
  end.to_h
  puts JSON.generate(error: e.class.name, details: details)
end
