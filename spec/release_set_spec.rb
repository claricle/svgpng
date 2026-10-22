# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
require_relative "../lib/svgpng/release_set"

RSpec.describe Svgpng::ReleaseSet do
  let(:root) { Dir.mktmpdir("svgpng-release-set-") }
  let(:release_dir) { File.join(root, "gems") }
  let(:manifest_path) { File.join(root, "checksums.yml") }
  let(:contents) { "staged gem bytes" }
  let(:entries) do
    described_class::TARGETS.map do |target|
      filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
      { "target" => target, "path" => filename, "sha256" => Digest::SHA256.hexdigest(contents) }
    end
  end

  before do
    FileUtils.mkdir_p(release_dir)
    entries.each { |entry| File.binwrite(File.join(release_dir, entry.fetch("path")), contents) }
    File.write(manifest_path, YAML.dump("schema_version" => 1, "version" => "0.1.0", "artifacts" => entries))
  end

  after { FileUtils.rm_rf(root) }

  it "verifies and reports the exact eight staged artifacts" do
    paths = described_class.verify!(directory: release_dir, manifest_path: manifest_path)

    expect(paths.length).to eq(8)
    expect(paths.map { |path| File.basename(path) }.sort).to eq(entries.map { |entry| entry.fetch("path") }.sort)
  end

  it "rejects a changed artifact by streaming its digest" do
    File.binwrite(File.join(release_dir, entries.first.fetch("path")), "changed gem bytes")

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /SHA-256 mismatch/)
  end

  it "rejects a missing artifact" do
    File.delete(File.join(release_dir, entries.first.fetch("path")))

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /missing:/)
  end

  it "rejects an additional gem in the staged directory" do
    File.binwrite(File.join(release_dir, "svgpng-0.1.0-extra.gem"), "extra")

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /unexpected:/)
  end

  it "rejects traversal paths in the manifest" do
    entries.first["path"] = "../svgpng-0.1.0-arm64-darwin.gem"
    File.write(manifest_path, YAML.dump("schema_version" => 1, "version" => "0.1.0", "artifacts" => entries))

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /simple basename/)
  end

  it "rejects a manifest with a missing target" do
    entries.pop
    File.write(manifest_path, YAML.dump("schema_version" => 1, "version" => "0.1.0", "artifacts" => entries))

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /missing targets: ruby/)
  end

  it "rejects symlinked artifact files" do
    path = File.join(release_dir, entries.first.fetch("path"))
    File.delete(path)
    File.symlink(File::NULL, path)

    expect { described_class.verify!(directory: release_dir, manifest_path: manifest_path) }
      .to raise_error(described_class::VerificationError, /must not be a symlink/)
  end
end
