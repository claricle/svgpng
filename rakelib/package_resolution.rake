# frozen_string_literal: true

require_relative "../lib/svgpng"
require_relative "../lib/svgpng/release_set"
require_relative "../lib/svgpng/package_resolution"

namespace :svgpng do
  desc "Resolve and install staged gems through a temporary local index (no network)"
  task :verify_package_resolution do
    directory = ENV.fetch("SVGPNG_RELEASE_DIR", nil)
    manifest = ENV.fetch("SVGPNG_RELEASE_MANIFEST", nil)
    destination = ENV.fetch("SVGPNG_RESOLUTION_DESTINATION", nil)
    raise "Set SVGPNG_RELEASE_DIR to the staged gem directory" if directory.to_s.empty?
    raise "Set SVGPNG_RELEASE_MANIFEST to the staged checksums manifest" if manifest.to_s.empty?
    raise "Set SVGPNG_RESOLUTION_DESTINATION to an empty temporary install directory" if destination.to_s.empty?

    result = Svgpng::PackageResolution.verify!(directory: directory, manifest_path: manifest, destination: destination)
    puts "Resolved and installed #{result[:name]} #{result[:version]} for #{result[:platform]} from staged local gems."
    puts "This checks resolution and installation only; native rendering acceptance remains pending."
  rescue Svgpng::PackageResolution::VerificationError => e
    raise "Package-resolution verification failed: #{e.message}"
  end
end
