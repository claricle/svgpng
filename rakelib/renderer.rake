# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "shellwords"

# Local one-host linker for developer experiments, never release packaging.
module SvgpngRendererBuild
  REQUIRED_PATHS = %w[
    SVGPNG_CARGO_HOME SVGPNG_LIBPNG_PREFIX SVGPNG_RUSTUP_HOME SVGPNG_ZLIB_PREFIX
  ].freeze

  module_function

  def run
    abort "native:build_renderer currently supports a macOS host only" unless RUBY_PLATFORM.match?(/darwin/)

    values = paths
    output = output_path
    libpng, zlib = dependency_prefixes(values)
    Rake::Task["native:check_encoder"].invoke
    archive = build_rust(values, output)
    link(libpng, zlib, archive, output)
    puts "Built local renderer library at #{output} (not a release artifact)."
  end

  def paths
    REQUIRED_PATHS.to_h do |name|
      value = ENV.fetch(name, "")
      abort "Set #{name} explicitly for this local native build" if value.empty?

      [name, File.realpath(value)]
    rescue Errno::ENOENT
      abort "#{name} does not name an existing path"
    end
  end

  def output_path
    value = ENV.fetch("SVGPNG_RENDERER_OUTPUT", "")
    abort "Set SVGPNG_RENDERER_OUTPUT to an isolated .dylib path" if value.empty?

    output = File.expand_path(value)
    abort "SVGPNG_RENDERER_OUTPUT must end in .dylib" unless output.end_with?(".dylib")

    FileUtils.mkdir_p(File.dirname(output))
    directory = File.realpath(File.dirname(output))
    unless directory.start_with?("/private/tmp/")
      abort "SVGPNG_RENDERER_OUTPUT must be an isolated path below /private/tmp"
    end
    File.join(directory, File.basename(output))
  end

  def dependency_prefixes(values)
    libpng = values.fetch("SVGPNG_LIBPNG_PREFIX")
    zlib = values.fetch("SVGPNG_ZLIB_PREFIX")
    { libpng => %w[include/png.h lib/libpng16.a], zlib => %w[include/zlib.h lib/libz.a] }.each do |prefix, files|
      files.each { |relative| require_file!(File.join(prefix, relative)) }
    end
    [libpng, zlib]
  end

  def require_file!(path)
    abort "Missing explicit static dependency file: #{path}" unless File.file?(path)
  end

  def build_rust(values, output)
    cargo_home = values.fetch("SVGPNG_CARGO_HOME")
    cargo = File.join(cargo_home, "bin", "cargo")
    abort "Missing isolated Cargo executable: #{cargo}" unless File.executable?(cargo)

    source = File.expand_path("../native/svgpng_renderer", __dir__)
    target = File.join(File.dirname(output), "cargo-target")
    build_cargo_archive(cargo_environment(values, target), cargo, source)
    archive = File.join(target, "release", "libsvgpng_renderer.a")
    require_file!(archive)
    archive
  end

  def build_cargo_archive(environment, cargo, source)
    Rake::FileUtilsExt.sh(environment, cargo, "build", "--manifest-path",
                          File.join(source, "Cargo.toml"), "--release", "--locked", "--offline", "-j2")
  end

  def cargo_environment(values, target)
    cargo_home = values.fetch("SVGPNG_CARGO_HOME")
    { "CARGO_HOME" => cargo_home, "CARGO_NET_OFFLINE" => "true",
      "CARGO_TARGET_DIR" => target,
      "PATH" => "#{File.join(cargo_home, "bin")}:#{ENV.fetch("PATH", "")}",
      "RUSTUP_HOME" => values.fetch("SVGPNG_RUSTUP_HOME") }
  end

  def link(libpng, zlib, archive, output)
    compiler = Shellwords.split(ENV.fetch("SVGPNG_CC", RbConfig::CONFIG.fetch("CC")))
    shim = File.expand_path("../native/svgpng_shim", __dir__)
    Rake::FileUtilsExt.sh(*compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-dynamiclib",
                          "-I#{File.join(libpng, "include")}", "-I#{File.join(zlib, "include")}",
                          File.join(shim, "rgba.c"), File.join(shim, "encoder.c"),
                          "-Wl,-force_load,#{archive}", File.join(libpng, "lib/libpng16.a"),
                          File.join(zlib, "lib/libz.a"), "-lSystem", "-lc", "-lm",
                          "-o", output)
  end
end

namespace :native do
  desc "Build a local renderer dylib from explicit pinned prefixes (not a release artifact)"
  task(:build_renderer) { SvgpngRendererBuild.run }
end
