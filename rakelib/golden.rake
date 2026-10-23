# frozen_string_literal: true

require "tmpdir"
require "yaml"
require_relative "../spec/support/golden_corpus"

# Keep regeneration provenance separate from the renderer subprocess contract.
module GoldenUpdate
  module_function

  def required(name)
    value = ENV.fetch(name, "")
    abort "Set #{name} explicitly before updating goldens" if value.strip.empty?
    value
  end

  def renderer(library, impact) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize -- One auditable provenance schema.
    vendor = YAML.safe_load_file(File.join(GoldenCorpus::REPOSITORY, "vendor/manifest.yml"))
    sources = vendor.fetch("sources")
    fork = sources.fetch("claricle_fork")
    {
      "resvg" => sources.fetch("resvg").fetch("version"),
      "libpng" => sources.fetch("libpng").fetch("version"),
      "zlib" => sources.fetch("zlib").fetch("version"),
      "rust" => vendor.fetch("build").fetch("rust_toolchain_used"),
      "source" => {
        "upstream_commit" => sources.fetch("resvg").fetch("upstream_commit"),
        "fork_commit" => fork.fetch("commit"),
        "patches" => fork.fetch("patches"),
        "source_sha256" => fork.fetch("source_sha256"),
        "cargo_lock_sha256" => fork.fetch("cargo_lock_sha256"),
        "archives" => %w[resvg libpng zlib].to_h { |name| [name, sources.fetch(name).fetch("archive")] }
      },
      "artifact" => { "sha256" => Digest::SHA256.file(library).hexdigest, "bytes" => File.size(library) },
      "build" => {
        "command" => required("SVGPNG_GOLDEN_BUILD_COMMAND"),
        "toolchain" => required("SVGPNG_GOLDEN_TOOLCHAIN"),
        "declared" => vendor.fetch("build"),
        "ruby" => RUBY_DESCRIPTION,
        "platform" => RUBY_PLATFORM
      },
      "compatibility" => impact
    }
  end

  def render(manifest, library) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize -- Stage every result before writing any fixture.
    manifest.fetch("fixtures").filter_map do |entry|
      output = GoldenCorpus.run(entry, "SVGPNG_TEST_NATIVE_LIBRARY" => library)
      if entry["error"]
        raise "Changed error for #{entry.fetch("svg")}: #{output}" unless output.fetch("error") == entry["error"]

        entry["expected"] = output
        next
      end
      bytes = output.fetch("png").unpack1("m0")
      digest = Digest::SHA256.hexdigest(bytes)
      puts "#{entry.fetch("svg")}: #{entry.fetch("png_sha256")} -> #{digest}"
      entry["png_sha256"] = digest
      entry["expected"] = output.except("png")
      [File.join(GoldenCorpus::ROOT, entry.fetch("png")), bytes]
    end
  end

  def update # rubocop:disable Metrics/MethodLength, Metrics/AbcSize -- Keep the guarded regeneration transaction visible.
    unless ENV["SVGPNG_COMPATIBILITY_UPDATE"] == "yes"
      abort "Set SVGPNG_COMPATIBILITY_UPDATE=yes and review version/CHANGELOG impact explicitly"
    end
    library = File.realpath(required("SVGPNG_TEST_NATIVE_LIBRARY"))
    impact = required("SVGPNG_COMPATIBILITY_IMPACT")
    manifest = GoldenCorpus.manifest
    GoldenCorpus.verify_inputs!(manifest)
    replacement = renderer(library, impact)
    puts "Reviewed version/CHANGELOG impact: #{impact}"
    puts "Old renderer:\n#{JSON.pretty_generate(manifest.fetch("renderer"))}"
    puts "New renderer:\n#{JSON.pretty_generate(replacement)}"
    outputs = render(manifest, library)
    raise "Native artifact changed during regeneration" unless Digest::SHA256.file(library).hexdigest ==
                                                               replacement.fetch("artifact").fetch("sha256")

    manifest["renderer"] = replacement
    outputs.each { |path, bytes| File.binwrite(path, bytes) }
    File.write(File.join(GoldenCorpus::ROOT, "manifest.json"), "#{JSON.pretty_generate(manifest)}\n")
  end
end

namespace :svgpng do
  desc "Verify committed golden input and output checksums without rendering"
  task :verify_manifest do
    GoldenCorpus.verify_inputs!(GoldenCorpus.manifest)
    puts "Verified golden SVG, font, PNG and encoding checksums."
  end

  desc "Intentionally update golden bytes after reviewing dependency and compatibility changes"
  task :update_goldens do
    GoldenUpdate.update
  end
end
