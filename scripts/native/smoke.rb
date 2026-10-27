# frozen_string_literal: true

require "svgpng"

expected = ARGV.fetch(0)
abort "Wrong installed platform" unless Gem.loaded_specs.fetch("svgpng").platform.to_s == expected
destination = File.expand_path(ARGV.fetch(1))
installed = Gem.loaded_specs.fetch("svgpng").full_gem_path
abort "SVGPNG was loaded outside the isolated install" unless installed.start_with?("#{destination}/gems/")
result = Svgpng.render('<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>',
                       profile: {}, fonts: {}, fallback_fonts: [])
abort "Render dimensions mismatch" unless [result.width, result.height] == [2, 3]
png = result.png_bytes
abort "Invalid PNG signature" unless png.byteslice(0, 8) == "\x89PNG\r\n\x1A\n".b
abort "PNG dimensions mismatch" unless png.byteslice(16, 8).unpack("N2") == [2, 3]
puts "Clean installed #{Gem.loaded_specs.fetch("svgpng").full_name}: 2x3 PNG"
