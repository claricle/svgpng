# frozen_string_literal: true

require "fileutils"
require "rubygems/resolver"
require "rubygems/source"
require "tmpdir"
require "zlib"
require_relative "native"
require_relative "release_set"

module Svgpng
  # Exercises RubyGems resolution against the verified staged set and local index.
  module PackageResolution
    class VerificationError < StandardError; end

    def self.verify!(directory:, manifest_path:, destination:)
      if File.exist?(destination) && (!File.directory?(destination) || !Dir.empty?(destination))
        raise VerificationError, "install destination must be absent or an empty directory"
      end

      paths = ReleaseSet.verify!(directory: directory, manifest_path: manifest_path)
      Dir.mktmpdir("svgpng-resolution-") do |workspace|
        repository = File.join(workspace, "repository")
        FileUtils.mkdir_p(File.join(repository, "gems"))
        paths.each { |path| FileUtils.cp(path, File.join(repository, "gems", File.basename(path))) }
        generate_index(repository)
        install_local(repository, destination)
      end
    rescue ReleaseSet::VerificationError => e
      raise VerificationError, "staged release-set validation failed: #{e.message}"
    end

    def self.generate_index(repository)
      specs = Dir.glob(File.join(repository, "gems", "*.gem")).map { |path| Gem::Package.new(path).spec }
      quick = File.join(repository, "quick", "Marshal.4.8")
      FileUtils.mkdir_p(quick)
      specs.each do |spec|
        path = File.join(quick, "#{spec.full_name}.gemspec.rz")
        File.binwrite(path, Zlib::Deflate.deflate(Marshal.dump(spec)))
      end
      tuples = specs.map { |spec| [spec.name, spec.version, spec.platform] }
      %w[specs.4.8 latest_specs.4.8].each do |name|
        File.open(File.join(repository, "#{name}.gz"), "wb") do |file|
          Zlib::GzipWriter.wrap(file) { |gzip| gzip.write(Marshal.dump(tuples)) }
        end
      end
    end
    private_class_method :generate_index

    def self.install_local(repository, destination)
      target = ReleaseSet::TARGETS.find { |candidate| candidate != "ruby" && candidate == Gem::Platform.local.to_s }
      target ||= Native.send(:compatible_target, Gem::Platform.local)
      raise VerificationError, "no supported native package for local platform #{Gem::Platform.local}" unless target

      source = Gem::Source.new("file://#{File.realpath(repository)}")
      request = Gem::Resolver.new([Gem::Dependency.new("svgpng", "= 0.1.0")],
                                  Gem::Resolver::IndexSet.new(source)).resolve
                             .find { |activation| activation.spec.name == "svgpng" }
      raise VerificationError, "local full-set index did not resolve svgpng 0.1.0" unless request
      unless request.spec.platform.to_s == target
        raise VerificationError,
              "RubyGems selected #{request.spec.platform}; supported local target is #{target}"
      end

      package = File.join(repository, "gems", "#{request.spec.full_name}.gem")
      raise VerificationError, "resolved package is missing from verified local set" unless File.file?(package)

      installed = Gem::Installer.at(package, install_dir: destination, wrappers: false, document: []).install
      unless installed.platform.to_s == target
        raise VerificationError,
              "installed platform #{installed.platform} does not match supported local target #{target}"
      end
      { name: installed.name, version: installed.version.to_s, platform: installed.platform.to_s }.freeze
    rescue Gem::Exception, IOError, SystemCallError => e
      raise VerificationError, "local gem resolution/install failed: #{e.message}"
    end
    private_class_method :install_local
  end
end
