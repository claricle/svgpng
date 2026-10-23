# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rubygems/package"
require "tmpdir"
require_relative "../../lib/svgpng/release_set"

# Stage only the selected payload; building the shell can never collect native files.
target, library, destination = ARGV
abort "Usage: package.rb TARGET LIBRARY_OR_DASH OUTPUT" unless destination
abort "Unknown target" unless Svgpng::ReleaseSet::TARGETS.include?(target)
root = File.expand_path("../..", __dir__)
FileUtils.mkdir_p(destination)
destination = File.expand_path(destination)
# Keep stage lifetime and Gem::Package's working directory together.
# rubocop:disable-next Metrics/BlockLength
Dir.mktmpdir("svgpng-candidate-") do |stage|
  specification = Gem::Specification.load(File.join(root, "svgpng.gemspec"))
  specification.platform = Gem::Platform.new(target)
  specification.files.each do |relative|
    next if relative.start_with?("lib/svgpng/native/")

    path = File.join(stage, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(File.join(root, relative), path)
  end
  specification.files = specification.files.reject { |path| path.start_with?("lib/svgpng/native/") }
  unless target == "ruby"
    abort "Native payload must be a regular file" unless File.file?(library) && !File.symlink?(library)
    suffix = case target
             when /darwin/ then "dylib"
             when /mingw/ then "dll"
             else "so"
             end
    relative = "lib/svgpng/native/#{target}/svgpng.#{suffix}"
    path = File.join(stage, relative)
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(library, path)
    specification.files << relative
  end
  filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
  package = File.join(destination, filename)
  Dir.chdir(stage) { Gem::Package.build(specification, false, false, package) }
  Svgpng::ReleaseSet::Package.new(package, target).verify!
  File.write("#{package}.sha256", "#{Digest::SHA256.file(package).hexdigest}  #{filename}\n")
end
