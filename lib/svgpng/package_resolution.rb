# frozen_string_literal: true

require "fileutils"
require "rubygems/package"
require "rubygems/resolver"
require "rubygems/source"
require "tmpdir"
require "zlib"
require_relative "../svgpng"
require_relative "native"
require_relative "release_set"

module Svgpng
  # Exercises RubyGems resolution against the verified staged set and local index.
  # rubocop:disable Metrics/ModuleLength -- cohesive private pipeline helpers keep the public surface to verify!.
  module PackageResolution
    class VerificationError < StandardError; end

    def self.verify!(directory:, manifest_path:, destination:)
      verify_destination!(destination)

      paths = ReleaseSet.verify!(directory: directory, manifest_path: manifest_path)
      Dir.mktmpdir("svgpng-resolution-") do |workspace|
        resolve_staged(paths, workspace, destination)
      end
    rescue ReleaseSet::VerificationError => e
      raise VerificationError, "staged release-set validation failed: #{e.message}"
    end

    def self.verify_destination!(destination)
      return unless File.exist?(destination) && (!File.directory?(destination) || !Dir.empty?(destination))

      raise VerificationError, "install destination must be absent or an empty directory"
    end
    private_class_method :verify_destination!

    def self.resolve_staged(paths, workspace, destination)
      repository = stage_repository(paths, workspace)
      generate_index(repository)
      install_local(repository, destination)
    end
    private_class_method :resolve_staged

    def self.generate_index(repository)
      specs = package_specs(repository)
      quick = File.join(repository, "quick", "Marshal.4.8")
      FileUtils.mkdir_p(quick)
      write_quick_specs(specs, quick)
      tuples = specs.map { |spec| [spec.name, spec.version, spec.platform] }
      write_index_files(repository, tuples)
    end
    private_class_method :generate_index

    def self.package_specs(repository)
      Dir.glob(File.join(repository, "gems", "*.gem")).map { |path| Gem::Package.new(path).spec }
    end
    private_class_method :package_specs

    def self.write_quick_specs(specs, quick)
      specs.each do |spec|
        path = File.join(quick, "#{spec.full_name}.gemspec.rz")
        File.binwrite(path, Zlib::Deflate.deflate(Marshal.dump(spec)))
      end
    end
    private_class_method :write_quick_specs

    def self.write_index_files(repository, tuples)
      %w[specs.4.8 latest_specs.4.8].each { |name| write_gzip_index(repository, name, tuples) }
    end
    private_class_method :write_index_files

    def self.write_gzip_index(repository, name, tuples)
      File.open(File.join(repository, "#{name}.gz"), "wb") do |file|
        Zlib::GzipWriter.wrap(file) { |gzip| gzip.write(Marshal.dump(tuples)) }
      end
    end
    private_class_method :write_gzip_index

    def self.stage_repository(paths, workspace)
      repository = File.join(workspace, "repository")
      gem_directory = File.join(repository, "gems")
      FileUtils.mkdir_p(gem_directory)
      paths.each { |path| FileUtils.cp(path, File.join(gem_directory, File.basename(path))) }
      repository
    end
    private_class_method :stage_repository

    def self.install_local(repository, destination)
      target = target_for(Gem::Platform.local)
      raise VerificationError, "no supported native package for local platform #{Gem::Platform.local}" unless target

      source = Gem::Source.new("file://#{File.realpath(repository)}")
      install_resolved(source, repository, destination, target)
    rescue Gem::Exception, IOError, SystemCallError => e
      raise VerificationError, "local gem resolution/install failed: #{e.message}"
    end
    private_class_method :install_local

    def self.install_resolved(source, repository, destination, target)
      request = resolve_full_set(source)
      raise VerificationError, "local full-set index did not resolve svgpng 0.1.0" unless request

      verify_selected_target!(request.spec.platform, target)
      installed = install_selected_package(repository, request.spec, destination, target)
      { name: installed.name, version: installed.version.to_s, platform: installed.platform.to_s }.freeze
    end
    private_class_method :install_resolved

    def self.install_selected_package(repository, resolver_spec, destination, target)
      package = package_path(repository, resolver_spec.spec)
      installed = install_package(package, destination)
      verify_installed_target!(installed.platform, target)
      installed
    end
    private_class_method :install_selected_package

    def self.verify_selected_target!(platform, target)
      return if platform.to_s == target

      raise VerificationError, "RubyGems selected #{platform}; supported local target is #{target}"
    end
    private_class_method :verify_selected_target!

    def self.verify_installed_target!(platform, target)
      return if platform.to_s == target

      raise VerificationError, "installed platform #{platform} does not match supported local target #{target}"
    end
    private_class_method :verify_installed_target!

    def self.target_for(platform)
      exact = ReleaseSet::TARGETS.find do |candidate|
        next false if candidate == "ruby"

        declared = Gem::Platform.new(candidate)
        declared.cpu == platform.cpu && declared.os == platform.os && declared.version == platform.version
      end
      exact || Native.send(:compatible_target, platform)
    end
    private_class_method :target_for

    def self.resolve_full_set(source)
      activations = Gem::Resolver.new([Gem::Dependency.new("svgpng", "= 0.1.0")],
                                      Gem::Resolver::IndexSet.new(source)).resolve
      activations.find { |activation| activation.spec.name == "svgpng" }
    end
    private_class_method :resolve_full_set

    def self.package_path(repository, spec)
      package = File.join(repository, "gems", "#{spec.full_name}.gem")
      raise VerificationError, "resolved package is missing from verified local set" unless File.file?(package)

      package
    end
    private_class_method :package_path

    def self.install_package(package, destination)
      Gem::Installer.at(package, install_dir: destination, wrappers: false, document: []).install
    end
    private_class_method :install_package
    # rubocop:enable Metrics/ModuleLength
  end
end
