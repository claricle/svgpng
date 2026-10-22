# frozen_string_literal: true

require_relative "../lib/svgpng/release_set"

namespace :svgpng do
  desc "Verify the staged local release candidate set (read-only)"
  task :verify_release_set do
    directory = ENV.fetch("SVGPNG_RELEASE_DIR", nil)
    manifest = ENV.fetch("SVGPNG_RELEASE_MANIFEST", nil)
    raise "Set SVGPNG_RELEASE_DIR to the staged gem directory" if directory.nil? || directory.empty?
    raise "Set SVGPNG_RELEASE_MANIFEST to the staged checksums manifest" if manifest.nil? || manifest.empty?

    paths = Svgpng::ReleaseSet.verify!(directory: directory, manifest_path: manifest)
    paths.each { |path| puts "verified #{path}" }
    puts "Verified #{paths.length} staged release artifacts."
    puts "Published download and package-resolution checks remain pending."
  rescue Svgpng::ReleaseSet::VerificationError => e
    raise "Release-set verification failed: #{e.message}"
  end
end
