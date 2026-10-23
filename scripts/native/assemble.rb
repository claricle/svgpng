# frozen_string_literal: true

require "digest"
require "json"
require_relative "../../lib/svgpng/release_set"

# JSON is also valid YAML; keep this manifest consumable by the strict verifier.
directory = File.expand_path(ARGV.fetch(0))
artifacts = Svgpng::ReleaseSet::TARGETS.map do |target|
  filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
  path = File.join(directory, filename)
  { "target" => target, "path" => filename, "sha256" => Digest::SHA256.file(path).hexdigest }
end
manifest = File.join(directory, "checksums.json")
File.write(manifest, "#{JSON.pretty_generate({ schema_version: 1, version: "0.1.0", artifacts: artifacts })}\n")
Svgpng::ReleaseSet.verify!(directory: directory, manifest_path: manifest)
puts "Verified all eight candidate gems: #{manifest}"
