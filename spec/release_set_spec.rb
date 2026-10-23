# frozen_string_literal: true

require "digest"
require "fileutils"
require "rubygems/package"
require "tmpdir"
require "yaml"
require_relative "../lib/svgpng/release_set"

RSpec.describe Svgpng::ReleaseSet do
  let(:root) { Dir.mktmpdir("svgpng-release-set-") }
  let(:release_dir) { File.join(root, "gems") }
  let(:manifest_path) { File.join(root, "checksums.yml") }

  before do
    FileUtils.mkdir_p(release_dir)
    described_class::TARGETS.each { |target| build_package(target) }
    write_manifest
  end

  after { FileUtils.rm_rf(root) }

  it "verifies metadata, target payload, and the exact eight local packages" do
    paths = described_class.verify!(directory: release_dir, manifest_path: manifest_path)

    expect(paths.length).to eq(8)
    expect(paths.map { |path| File.basename(path) }.sort)
      .to eq(artifact_entries.map { |entry| entry.fetch("path") }.sort)
  end

  it "rejects a changed package by streaming its digest" do
    File.binwrite(File.join(release_dir, artifact_entries.first.fetch("path")), "changed gem bytes")

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /SHA-256 mismatch/)
  end

  it "rejects a missing artifact" do
    File.delete(File.join(release_dir, artifact_entries.first.fetch("path")))

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /missing:/)
  end

  it "rejects an additional gem in the staged directory" do
    File.binwrite(File.join(release_dir, "svgpng-0.1.0-extra.gem"), "extra")

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /unexpected:/)
  end

  it "rejects traversal paths in the manifest" do
    entries = artifact_entries
    entries.first["path"] = "../svgpng-0.1.0-arm64-darwin.gem"
    save_manifest(entries)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /simple basename/)
  end

  it "rejects a manifest with a missing target" do
    entries = artifact_entries
    entries.pop
    save_manifest(entries)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /missing targets: ruby/)
  end

  it "rejects symlinked artifact files" do
    path = File.join(release_dir, artifact_entries.first.fetch("path"))
    File.delete(path)
    File.symlink(File::NULL, path)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /must not be a symlink/)
  end

  it "rejects package metadata for a different platform" do
    entry = artifact_entries.find { |item| item.fetch("target") == "x86_64-linux" }
    build_package("x86_64-linux", platform: Gem::Platform.new("aarch64-linux"))
    refresh_digest(entry)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /metadata must be svgpng 0.1.0 for x86_64-linux/)
  end

  it "rejects a native package with the wrong shared-library path" do
    entry = artifact_entries.find { |item| item.fetch("target") == "arm64-darwin" }
    build_package("arm64-darwin", native_path: "lib/svgpng/native/x86_64-darwin/svgpng.dylib")
    refresh_digest(entry)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError,
                      %r{expected exactly lib/svgpng/native/arm64-darwin/svgpng.dylib})
  end

  it "rejects a ruby shell package containing a shared library" do
    entry = artifact_entries.find { |item| item.fetch("target") == "ruby" }
    build_package("ruby", native_path: "lib/svgpng/native/x86_64-linux/svgpng.so")
    refresh_digest(entry)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /ruby shell gem must not contain shared libraries/)
  end

  it "rejects package install hooks" do
    entry = artifact_entries.find { |item| item.fetch("target") == "aarch64-linux" }
    build_package("aarch64-linux", extensions: ["extconf.rb"])
    refresh_digest(entry)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /must not declare extensions or executables/)
  end

  def artifact_entries
    described_class::TARGETS.map do |target|
      filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
      { "target" => target, "path" => filename,
        "sha256" => Digest::SHA256.file(File.join(release_dir, filename)).hexdigest }
    end
  end

  def write_manifest
    save_manifest(artifact_entries)
  end

  def save_manifest(entries)
    File.write(manifest_path, YAML.dump("schema_version" => 1, "version" => "0.1.0", "artifacts" => entries))
  end

  def refresh_digest(entry)
    entry["sha256"] = Digest::SHA256.file(File.join(release_dir, entry.fetch("path"))).hexdigest
    save_manifest(artifact_entries)
  end

  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength -- Builds a minimal multi-platform package fixture.
  def build_package(target, platform: target == "ruby" ? Gem::Platform::RUBY : Gem::Platform.new(target),
                    native_path: nil, extensions: [])
    filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
    source = File.join(root, "source-#{target}")
    FileUtils.mkdir_p(File.join(source, "lib"))
    files = ["lib/svgpng.rb"]
    File.write(File.join(source, "lib/svgpng.rb"), "# test package payload\n")
    extensions.each do |extension|
      FileUtils.mkdir_p(File.dirname(File.join(source, extension)))
      File.write(File.join(source, extension), "# fixture install hook\n")
      files << extension
    end
    if native_path
      FileUtils.mkdir_p(File.dirname(File.join(source, native_path)))
      File.binwrite(File.join(source, native_path), "synthetic package fixture; not a native binary")
      files << native_path
    elsif target != "ruby"
      path = shared_library_path(target)
      FileUtils.mkdir_p(File.dirname(File.join(source, path)))
      File.binwrite(File.join(source, path), "synthetic package fixture; not a native binary")
      files << path
    end

    spec = Gem::Specification.new do |gem_spec|
      gem_spec.name = "svgpng"
      gem_spec.version = "0.1.0"
      gem_spec.platform = platform
      gem_spec.summary = "Local release verifier fixture"
      gem_spec.authors = ["Spec"]
      gem_spec.license = "MIT"
      gem_spec.homepage = "https://example.invalid/svgpng-fixture"
      gem_spec.required_ruby_version = ">= 3.2"
      gem_spec.files = files
      gem_spec.extensions = extensions
      gem_spec.require_paths = ["lib"]
    end
    output = File.join(release_dir, filename)
    Dir.chdir(source) { Gem::Package.build(spec, false, false, output) }
  end

  def shared_library_path(target)
    extension = case target
                when /darwin/ then "dylib"
                when /mingw/ then "dll"
                else "so"
                end
    "lib/svgpng/native/#{target}/svgpng.#{extension}"
  end
end
