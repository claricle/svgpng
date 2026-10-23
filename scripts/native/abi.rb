# frozen_string_literal: true

# Fail with the original loader/ABI message before corpus diagnostics normalize it.
# Exercise coexistence with Ruby's system zlib before loading the private codec.
require "zlib"
require "svgpng"
require "svgpng/native"

library = File.realpath(ARGV.fetch(0))
Svgpng::Native.define_singleton_method(:packaged_library_path) { library }
handle = Fiddle::Handle.new(library, Fiddle::RTLD_NOW)
%w[svgpng_v1_rgba_to_straight svgpng_v1_png_encode svgpng_v1_png_free
   svgpng_v1_root_attributes svgpng_v1_render svgpng_v1_render_free].each do |symbol|
  handle[symbol]
end
Svgpng.render('<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>',
              profile: {}, fonts: {}, fallback_fonts: [])
puts "Native ABI load and render passed"
