# frozen_string_literal: true

require "digest"
require "rubygems/package"
require "tmpdir"
require "yaml"

module Svgpng
  # Validates the staged local 0.1.0 package set without mutating it.
  module ReleaseSet
    VERSION = "0.1.0"
    TARGETS = %w[
      arm64-darwin x86_64-darwin x86_64-linux aarch64-linux
      x86_64-linux-musl aarch64-linux-musl x64-mingw-ucrt ruby
    ].freeze
    TARGET_PATTERN = TARGETS.reject { |target| target == "ruby" }.join("|").freeze
    GEM_NAME = /\Asvgpng-0\.1\.0(?:-(?:#{TARGET_PATTERN}))?\.gem\z/
    SHA256 = /\A[a-f0-9]{64}\z/
    MANIFEST_KEYS = %w[schema_version version artifacts].freeze
    ARTIFACT_KEYS = %w[target path sha256].freeze
    CHUNK_SIZE = 1024 * 1024

    class VerificationError < StandardError; end

    def self.verify!(directory:, manifest_path:)
      raise VerificationError, "release directory must not be a symlink" if File.symlink?(directory)

      release_dir = File.expand_path(directory)
      raise VerificationError, "release directory does not exist: #{release_dir}" unless File.directory?(release_dir)

      artifacts = Manifest.new(manifest_path).artifacts
      Directory.new(release_dir).verify!(artifacts)
    end

    # Reads the versioned manifest and validates its schema and artifact names.
    class Manifest
      attr_reader :artifacts

      def initialize(path)
        @path = File.expand_path(path)
        @artifacts = read_artifacts
      end

      private

      def read_artifacts
        raise VerificationError, "release manifest is missing: #{@path}" unless File.file?(@path)
        raise VerificationError, "release manifest must not be a symlink: #{@path}" if File.symlink?(@path)

        data = load_yaml
        validate_header(data)
        build_artifacts(manifest_entries(data))
      end

      def manifest_entries(data)
        entries = data.fetch("artifacts")
        raise VerificationError, "manifest artifacts must be an array" unless entries.is_a?(Array)

        entries.map { |entry| validate_entry(entry) }
      end

      def build_artifacts(parsed)
        validate_targets(parsed.map(&:first))
        paths = parsed.map { |row| row[1] }
        raise VerificationError, "manifest artifact paths must be unique" unless paths.uniq.length == paths.length

        parsed.to_h { |target, path, digest| [path, [target, digest]] }
      end

      def load_yaml
        YAML.safe_load_file(@path, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue Psych::Exception => e
        raise VerificationError, "invalid YAML manifest #{@path}: #{e.message}"
      end

      def validate_header(data)
        unless data.is_a?(Hash) && data.keys.sort == MANIFEST_KEYS.sort
          raise VerificationError, "manifest must contain exactly: #{MANIFEST_KEYS.join(", ")}"
        end
        raise VerificationError, "manifest schema_version must be 1" unless data["schema_version"] == 1
        raise VerificationError, "manifest version must be #{VERSION}" unless data["version"] == VERSION
      end

      def validate_targets(targets)
        return if targets.sort == TARGETS.sort

        raise VerificationError, "manifest must list exactly eight targets (#{target_problems(targets)})"
      end

      def target_problems(targets)
        missing = TARGETS - targets
        unexpected = targets - TARGETS
        duplicates = targets.tally.select { |_target, count| count > 1 }.keys
        issues = [target_issue("missing", missing), target_issue("unexpected", unexpected),
                  target_issue("duplicate", duplicates)]
        issues
          .compact
          .join("; ")
      end

      def target_issue(kind, values)
        "#{kind} targets: #{values.join(", ")}" unless values.empty?
      end

      def validate_entry(entry)
        unless entry.is_a?(Hash) && entry.keys.sort == ARTIFACT_KEYS.sort
          raise VerificationError, "each artifact must contain exactly: #{ARTIFACT_KEYS.join(", ")}"
        end

        target = entry["target"]
        path = entry["path"]
        digest = entry["sha256"]
        validate_path(target, path)
        validate_digest(path, digest)
        [target, path, digest]
      end

      def validate_digest(path, digest)
        return if digest.is_a?(String) && SHA256.match?(digest)

        raise VerificationError, "#{path}: sha256 must be 64 lowercase hexadecimal characters"
      end

      def validate_path(target, path)
        raise VerificationError, "artifact target must be a string" unless target.is_a?(String)

        validate_basename(path)
        raise VerificationError, "invalid release gem filename: #{path}" unless GEM_NAME.match?(path)

        expected = target == "ruby" ? "svgpng-#{VERSION}.gem" : "svgpng-#{VERSION}-#{target}.gem"
        raise VerificationError, "#{target}: expected filename #{expected}" unless path == expected
      end

      def validate_basename(path)
        return if path.is_a?(String) && File.basename(path) == path && path != "." && path != ".."

        raise VerificationError, "artifact path must be a simple basename"
      end
    end

    # Compares the manifest against regular files in the local candidate dir.
    class Directory
      def initialize(path)
        @path = path
      end

      def verify!(artifacts)
        paths = actual_paths
        expected = artifacts.keys.sort
        validate_set(paths, expected)
        expected.each { |name| verify_artifact(name, artifacts.fetch(name)) }
        expected.map { |name| File.join(@path, name) }.freeze
      end

      private

      def actual_paths
        Dir.children(@path).select { |name| name.end_with?(".gem") }.sort
      end

      def validate_set(actual, expected)
        missing = expected - actual
        extra = actual - expected
        raise VerificationError, "release set mismatch; missing: #{missing.join(", ")}" unless missing.empty?
        raise VerificationError, "release set mismatch; unexpected: #{extra.join(", ")}" unless extra.empty?
      end

      def verify_artifact(name, artifact)
        target, expected_digest = artifact
        path = File.join(@path, name)
        raise VerificationError, "release artifact must not be a symlink: #{path}" if File.symlink?(path)
        raise VerificationError, "release artifact is not a regular file: #{path}" unless File.file?(path)

        actual_digest = digest(path)
        unless actual_digest == expected_digest
          raise VerificationError, "SHA-256 mismatch for #{path}: expected #{expected_digest}, got #{actual_digest}"
        end

        Package.new(path, target).verify!
      end

      def digest(path)
        result = Digest::SHA256.new
        File.open(path, "rb") do |file|
          while (chunk = file.read(CHUNK_SIZE))
            result.update(chunk)
          end
        end
        result.hexdigest
      end
    end

    # Inspects gem metadata and unpacked paths without installing the package.
    class Package
      def initialize(path, target)
        @path = path
        @target = target
      end

      def verify!
        package = Gem::Package.new(@path)
        validate_gemspec(package.spec)
        contents = package.contents
        validate_contents(contents)
        verify_payload(package)
      rescue Gem::Package::Error, Gem::Security::Exception, Zlib::Error => e
        raise VerificationError, "invalid gem package #{@path}: #{e.message}"
      end

      private

      def validate_gemspec(spec)
        platform = @target == "ruby" ? "ruby" : @target
        unless spec.name == "svgpng" && spec.version.to_s == VERSION && spec.platform.to_s == platform
          raise VerificationError, "#{@path}: gem metadata must be svgpng #{VERSION} for #{platform}"
        end
        return if spec.extensions.empty? && spec.executables.empty?

        raise VerificationError, "#{@path}: gem must not declare extensions or executables"
      end

      def validate_contents(contents)
        contents.each { |entry| validate_entry(entry) }
        libraries = contents.select { |entry| shared_library?(entry) }
        validate_shared_libraries(libraries)
      end

      def validate_entry(entry)
        if entry.start_with?("/") || entry.split("/").include?("..") || entry.include?(92.chr)
          raise VerificationError, "#{@path}: unsafe package path #{entry.inspect}"
        end
        return unless entry.start_with?("bin/") || entry.match?(/\.(?:sh|bat|ps1)\z/i)

        raise VerificationError, "#{@path}: packaged scripts are not allowed (#{entry})"
      end

      def validate_shared_libraries(libraries)
        if @target == "ruby" && !libraries.empty?
          raise VerificationError, "#{@path}: ruby shell gem must not contain shared libraries"
        end
        return if @target == "ruby" || libraries == [shared_library_path]

        raise VerificationError,
              "#{@path}: expected exactly #{shared_library_path}; found shared libraries: #{libraries.join(", ")}"
      end

      def verify_payload(package)
        return if @target == "ruby"

        Dir.mktmpdir("svgpng-gem-inspect-") do |destination|
          package.extract_files(destination)
          extracted = File.join(destination, shared_library_path)
          unless File.file?(extracted) && !File.symlink?(extracted)
            raise VerificationError, "#{@path}: expected packaged shared library #{shared_library_path}"
          end
        end
      end

      def shared_library?(entry)
        entry.match?(/\.(?:so|dylib|dll)\z/)
      end

      def shared_library_path
        extension = case @target
                    when /darwin/ then "dylib"
                    when /mingw/ then "dll"
                    else "so"
                    end
        "lib/svgpng/native/#{@target}/svgpng.#{extension}"
      end
    end
  end
end
