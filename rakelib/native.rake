# frozen_string_literal: true

require "rbconfig"
require "shellwords"
require "tmpdir"

# Keep dependency validation and both developer builds in one task.
namespace :native do # rubocop:disable Metrics/BlockLength
  desc "Run PNG encoder assertions against explicitly supplied pinned static dependencies"
  task :check_encoder do # rubocop:disable Metrics/BlockLength
    dependencies = {
      "SVGPNG_LIBPNG_PREFIX" => ["include/png.h", "lib/libpng16.a"],
      "SVGPNG_ZLIB_PREFIX" => ["include/zlib.h", "lib/libz.a"]
    }.to_h do |variable, files|
      prefix = ENV.fetch(variable, "")
      abort "Set #{variable} to the verified pinned dependency installation" if prefix.empty?

      prefix = File.realpath(prefix)
      files.each do |file|
        abort "Missing static dependency file: #{File.join(prefix, file)}" unless File.file?(File.join(prefix, file))
      end
      [variable, prefix]
    end

    png = dependencies.fetch("SVGPNG_LIBPNG_PREFIX")
    zlib = dependencies.fetch("SVGPNG_ZLIB_PREFIX")
    root = File.expand_path("../native/svgpng_shim", __dir__)
    # No -lpng/-lz lookup: these exact archives must provide the encoder closure.
    # encoder.c rejects header/runtime versions other than 1.6.59 and 1.3.2.
    Dir.mktmpdir("svgpng-encoder") do |directory|
      executable = File.join(directory, "test_encoder#{RbConfig::CONFIG.fetch("EXEEXT", "")}")
      compiler = Shellwords.split(ENV.fetch("SVGPNG_CC", RbConfig::CONFIG.fetch("CC")))
      sh(*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
         "-I#{File.join(png, "include")}", "-I#{File.join(zlib, "include")}",
         File.join(root, "encoder.c"), File.join(root, "test_encoder.c"),
         File.join(png, "lib/libpng16.a"), File.join(zlib, "lib/libz.a"), "-lm", "-o", executable)
      sh executable
      sh(*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
         "-DSVGPNG_ENCODER_FAULT_TEST", "-I#{File.join(png, "include")}",
         "-I#{File.join(zlib, "include")}", File.join(root, "test_encoder.c"),
         File.join(png, "lib/libpng16.a"), File.join(zlib, "lib/libz.a"), "-lm", "-o", executable)
      sh executable
    end
  end
end
