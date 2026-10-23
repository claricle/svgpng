# frozen_string_literal: true

require "digest"
require "fileutils"
require "rubygems/package"
require "open3"
require "rbconfig"
require "tmpdir"

# Builds and verifies one explicitly supplied, local development package.
# rubocop:disable-next Metrics/ModuleLength -- cohesive orchestration task with no public runtime API.
module SvgpngLocalPackage
  GEM_NAME = "svgpng-0.1.0-arm64-darwin.gem"
  PLATFORM = "arm64-darwin"
  LIBRARY_RELATIVE_PATH = "lib/svgpng/native/#{PLATFORM}/svgpng.dylib".freeze
  SYSTEM_LIBRARY = "/usr/lib/libSystem.B.dylib"
  BUNDLER_ENVIRONMENT = %w[
    RUBYOPT RUBYLIB BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLER_SETUP BUNDLER_VERSION
  ].freeze

  module_function

  def run
    artifact, label, output_dir = inputs
    package_path = File.join(output_dir, GEM_NAME)
    log_path = File.join(output_dir, "local-package.log")
    stage_and_build(artifact, label, package_path, log_path)
    install_and_smoke(package_path, output_dir, log_path)
    report_result(package_path)
  end

  def inputs
    artifact = required_file("SVGPNG_TEST_NATIVE_LIBRARY")
    label = required_label
    output_dir = required_output_directory
    require_arm64_artifact(artifact)
    inspect_dependencies(artifact)
    [artifact, label, output_dir]
  end

  def report_result(package_path)
    checksum_path = "#{package_path}.sha256"
    File.write(checksum_path, "#{Digest::SHA256.file(package_path).hexdigest}  #{GEM_NAME}\n")
    puts "Built and smoke-tested local developer gem: #{package_path}"
    puts "SHA-256: #{checksum_path}"
    puts "This is a one-host development artifact, not release qualification."
  end

  def required_file(variable)
    value = ENV.fetch(variable, "")
    abort "Set #{variable} to an explicit native dylib path" if value.empty?

    path = File.expand_path(value)
    unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == path && path.end_with?(".dylib")
      abort "#{variable} must name a regular, non-symlink .dylib file"
    end
    path
  rescue Errno::ENOENT, Errno::ELOOP
    abort "#{variable} does not name an existing regular file"
  end

  def required_label
    label = ENV.fetch("SVGPNG_DEV_LABEL", "")
    abort "Set SVGPNG_DEV_LABEL to identify this local developer build" unless label.match?(/\A[A-Za-z0-9._-]{1,64}\z/)

    label
  end

  def required_output_directory
    value = ENV.fetch("SVGPNG_DEV_PACKAGE_DIR", "")
    abort "Set SVGPNG_DEV_PACKAGE_DIR to an empty output directory below /private/tmp" if value.empty?

    directory = File.expand_path(value)
    abort "SVGPNG_DEV_PACKAGE_DIR must be below /private/tmp" unless directory.start_with?("/private/tmp/")
    FileUtils.mkdir_p(directory)
    directory = File.realpath(directory)
    abort "Resolved SVGPNG_DEV_PACKAGE_DIR must stay below /private/tmp" unless directory.start_with?("/private/tmp/")
    abort "SVGPNG_DEV_PACKAGE_DIR must be empty" unless Dir.empty?(directory)

    directory
  end

  def inspect_dependencies(artifact)
    output = otool_output(artifact)
    dependencies = output.lines.drop(1).map { |line| line.strip.split.first }.compact
    enforce_dependencies(dependencies, artifact)
    dependencies
  end

  def require_arm64_artifact(artifact)
    output, status = Open3.capture2("lipo", "-archs", artifact)
    unless status.success? && output.split.include?("arm64")
      abort "Supplied dylib must contain an arm64 slice for the arm64-darwin package"
    end
  rescue Errno::ENOENT
    abort "lipo is required to verify the supplied dylib architecture"
  end

  def otool_output(artifact)
    abort "otool is required to inspect the local dylib" unless RbConfig::CONFIG["host_os"].include?("darwin")

    output, status = Open3.capture2("otool", "-L", artifact)
    abort "otool -L failed for supplied dylib" unless status.success?
    output
  end

  def enforce_dependencies(dependencies, artifact)
    unexpected = dependencies.reject { |dependency| dependency == artifact || dependency == SYSTEM_LIBRARY }
    abort "Dylib has non-system dynamic dependencies: #{unexpected.join(", ")}" unless unexpected.empty?
    return if dependencies.include?(SYSTEM_LIBRARY)

    abort "Dylib must link only the system runtime; PNG/zlib must be static"
  end

  def stage_and_build(artifact, label, package_path, log_path)
    repository = File.expand_path("..", __dir__)
    Dir.mktmpdir("svgpng-local-package-") do |stage|
      stage_package_files(repository, stage, artifact)
      specification = local_specification(repository, label)
      Dir.chdir(stage) { Gem::Package.build(specification, false, false, package_path) }
      verify_package(package_path, label)
      append_log(log_path, "label=#{label}\nartifact=#{artifact}\nartifact_sha256=#{Digest::SHA256.file(artifact).hexdigest}\n")
      append_log(log_path, "otool_dependencies=#{inspect_dependencies(artifact).join(",")}\npackage=#{package_path}\n")
    end
  end

  def stage_package_files(repository, stage, artifact)
    %w[lib docs vendor].each { |directory| FileUtils.cp_r(File.join(repository, directory), stage) }
    FileUtils.cp(File.join(repository, "README.adoc"), stage)
    library = File.join(stage, LIBRARY_RELATIVE_PATH)
    FileUtils.mkdir_p(File.dirname(library))
    FileUtils.cp(artifact, library)
  end

  def local_specification(repository, label)
    specification = Gem::Specification.load(File.join(repository, "svgpng.gemspec"))
    abort "Could not load svgpng.gemspec" unless specification

    specification.platform = Gem::Platform.new(PLATFORM)
    specification.files = (specification.files + [LIBRARY_RELATIVE_PATH]).uniq
    specification.metadata = specification.metadata.merge(
      "svgpng.dev_only" => "true", "svgpng.dev_label" => label
    )
    specification
  end

  def verify_package(package_path, label)
    package = Gem::Package.new(package_path)
    spec = package.spec
    abort "Built gem metadata does not match the local package contract" unless metadata_matches?(spec, label)
    abort "Built gem omits its expected native library" unless spec.files.include?(LIBRARY_RELATIVE_PATH)
  end

  def metadata_matches?(spec, label)
    spec.name == "svgpng" && spec.version.to_s == "0.1.0" && spec.platform == Gem::Platform.new(PLATFORM) &&
      spec.metadata["svgpng.dev_only"] == "true" && spec.metadata["svgpng.dev_label"] == label
  end

  def install_and_smoke(package_path, output_dir, log_path)
    gem_home = File.join(output_dir, "gem-home")
    FileUtils.mkdir_p(gem_home)
    environment = isolated_gem_environment(gem_home)
    install_locally(package_path, gem_home, environment, log_path)
    smoke_installed_gem(environment, log_path)
  end

  def isolated_gem_environment(gem_home)
    BUNDLER_ENVIRONMENT.to_h { |name| [name, nil] }.merge("GEM_HOME" => gem_home, "GEM_PATH" => gem_home)
  end

  def install_locally(package_path, gem_home, environment, log_path)
    command = [RbConfig.ruby, "-S", "gem", "install", "--local", "--install-dir", gem_home,
               "--ignore-dependencies", "--no-document", package_path]
    output, status = Open3.capture2e(environment, *command)
    append_log(log_path, "install_command=#{command.join(" ")}\n#{output}")
    abort "Isolated local gem installation failed; see #{log_path}" unless status.success?
  end

  def smoke_installed_gem(environment, log_path)
    output, status = Open3.capture2e(environment, RbConfig.ruby, "-e", smoke_source)
    append_log(log_path, "smoke_output=#{output}")
    abort "Clean installed-gem render smoke failed; see #{log_path}" unless status.success?
  end

  def smoke_source
    <<~'RUBY'
      require "svgpng"
      result = Svgpng.render('<svg xmlns="http://www.w3.org/2000/svg" width="2" height="3"/>',
                             profile: {}, fonts: {}, fallback_fonts: [])
      abort "render dimensions mismatch" unless [result.width, result.height] == [2, 3]
      png = result.png_bytes
      abort "invalid PNG signature" unless png.byteslice(0, 8) == "\x89PNG\r\n\x1A\n".b
      abort "PNG dimensions mismatch" unless png.byteslice(16, 8).unpack("N2") == [2, 3]
      puts "installed=#{Gem.loaded_specs.fetch('svgpng').full_name} dimensions=#{result.width}x#{result.height}"
    RUBY
  end

  def append_log(path, contents)
    File.open(path, "a") { |file| file.write(contents) }
  end
end

namespace :native do
  desc "Build and clean-install one developer-labeled local arm64-darwin gem"
  task :local_package do
    SvgpngLocalPackage.run
  end
end
