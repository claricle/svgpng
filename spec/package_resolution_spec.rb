# frozen_string_literal: true

require "digest"
require "fileutils"
require "rubygems/package"
require "tmpdir"
require "yaml"
require_relative "../lib/svgpng"
require_relative "../lib/svgpng/release_set"
require_relative "../lib/svgpng/package_resolution"

RSpec.describe Svgpng::PackageResolution do
  let(:root) { Dir.mktmpdir("svgpng-package-resolution-") }
  let(:release_dir) { File.join(root, "staged") }
  let(:manifest) { File.join(root, "checksums.yml") }
  let(:destination) { File.join(root, "install") }

  before do
    FileUtils.mkdir_p(release_dir)
    Svgpng::ReleaseSet::TARGETS.each { |target| build_fixture_gem(target) }
    artifacts = Svgpng::ReleaseSet::TARGETS.map do |target|
      filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
      { "target" => target, "path" => filename,
        "sha256" => Digest::SHA256.file(File.join(release_dir, filename)).hexdigest }
    end
    File.write(manifest, YAML.dump("schema_version" => 1, "version" => "0.1.0", "artifacts" => artifacts))
  end

  after { FileUtils.rm_rf(root) }

  it "uses full-set RubyGems selection and fails closed on a platform mismatch" do
    result = described_class.verify!(directory: release_dir, manifest_path: manifest, destination: destination)
    expected = Svgpng::Native.send(:compatible_target, Gem::Platform.local)
    expect(result[:platform]).to eq(expected)
  rescue described_class::VerificationError => e
    expect(e.message).to match(/RubyGems selected|installed platform/)
  end

  it "rejects an incomplete staged set before installation" do
    File.delete(File.join(release_dir, "svgpng-0.1.0.gem"))
    expect do
      described_class.verify!(directory: release_dir, manifest_path: manifest, destination: destination)
    end.to raise_error(described_class::VerificationError, /missing:/)
    expect(File).not_to exist(destination)
  end

  def build_fixture_gem(target)
    platform = target == "ruby" ? Gem::Platform::RUBY : Gem::Platform.new(target)
    source = File.join(root, "fixture-#{target}")
    FileUtils.mkdir_p(File.join(source, "lib"))
    File.write(File.join(source, "lib", "svgpng.rb"), "# synthetic resolution fixture; no renderer\n")
    files = ["lib/svgpng.rb"]
    unless target == "ruby"
      extension = if target.include?("darwin")
                    "dylib"
                  else
                    (target.include?("mingw") ? "dll" : "so")
                  end
      path = "lib/svgpng/native/#{target}/svgpng.#{extension}"
      FileUtils.mkdir_p(File.dirname(File.join(source, path)))
      File.binwrite(File.join(source, path), "synthetic package fixture; not a native binary")
      files << path
    end
    spec = Gem::Specification.new do |gem|
      gem.name = "svgpng"
      gem.version = "0.1.0"
      gem.platform = platform
      gem.summary = "Synthetic package resolution fixture"
      gem.authors = ["Spec"]
      gem.license = "MIT"
      gem.homepage = "https://example.invalid/svgpng-resolution-fixture"
      gem.files = files
      gem.require_paths = ["lib"]
      gem.required_ruby_version = ">= 3.2"
    end
    filename = target == "ruby" ? "svgpng-0.1.0.gem" : "svgpng-0.1.0-#{target}.gem"
    Dir.chdir(source) { Gem::Package.build(spec, false, false, File.join(release_dir, filename)) }
  end
end
