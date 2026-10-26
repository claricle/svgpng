# frozen_string_literal: true

require "tmpdir"
require_relative "../../scripts/release/qualified_set"

RSpec.describe Svgpng::QualifiedRelease do
  let(:run) do
    { "id" => described_class::RUN, "head_sha" => described_class::SOURCE,
      "status" => "completed", "conclusion" => "success", "path" => ".github/workflows/native.yml",
      "repository" => { "full_name" => "claricle/svgpng" },
      "head_repository" => { "full_name" => "claricle/svgpng" } }
  end
  let(:artifact) do
    { "id" => described_class::ARTIFACT, "name" => "svgpng-0.1.0-eight-gem-candidate-set", "expired" => false,
      "workflow_run" => { "id" => described_class::RUN, "head_sha" => described_class::SOURCE } }
  end
  let(:jobs) do
    targets = Svgpng::ReleaseSet::TARGETS.reject { |target| target == "ruby" }
    names = %w[targets resolution].flat_map do |phase|
      targets.map { |target| "#{phase} (#{target}, runner, false) / qualify" }
    end
    (names + ["assemble"]).map { |name| { "name" => name, "conclusion" => "success" } }
  end
  let(:commit) { { "commit" => { "tree" => { "sha" => described_class::TREE } } } }

  it "accepts the complete successful qualification in the original repository" do
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }.not_to raise_error
  end

  it "rejects an unsuccessful run" do
    run["conclusion"] = "failure"
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }
      .to raise_error(described_class::Error, /unqualified run/)
  end

  it "rejects a fork's run" do
    run["head_repository"]["full_name"] = "other/svgpng"
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }
      .to raise_error(described_class::Error, /repository/)
  end

  it "rejects an artifact from another run" do
    artifact["workflow_run"]["id"] = 1
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }
      .to raise_error(described_class::Error, /artifact/)
  end

  it "rejects an expired artifact" do
    artifact["expired"] = true
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }
      .to raise_error(described_class::Error, /expired/)
  end

  it "requires every platform's resolution qualification" do
    jobs.first["name"] = "unrelated"
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }
      .to raise_error(described_class::Error, /missing targets qualification/)
    jobs.first["name"] = "targets (arm64-darwin, runner, false) / qualify"
    jobs.first["conclusion"] = "failure"
    expect { described_class.verify_provenance!(run, artifact, jobs, commit) }
      .to raise_error(described_class::Error, /qualification jobs/)
  end

  it "pins the approved manifest bytes" do
    expect(Digest::SHA256.file(described_class::MANIFEST).hexdigest).to eq(described_class::MANIFEST_SHA)
  end

  it "treats only HTTP 404 as an unpublished artifact" do
    allow(Net::HTTP).to receive(:get_response).and_return(Net::HTTPNotFound.new("1.1", "404", "Not Found"))
    expect(described_class.remote_digest("svgpng-0.1.0.gem")).to be_nil
    allow(Net::HTTP).to receive(:get_response).and_return(Net::HTTPForbidden.new("1.1", "403", "Forbidden"))
    expect { described_class.remote_digest("svgpng-0.1.0.gem") }
      .to raise_error(described_class::Error, /download failed: 403/)
  end

  context "with local candidate bytes" do
    let(:directory) { Dir.mktmpdir("svgpng-publisher-spec-") }
    let(:path) { File.join(directory, "svgpng-0.1.0.gem") }
    let(:digest) { Digest::SHA256.hexdigest("qualified bytes") }
    let(:push) { spy("push") }

    before { File.binwrite(path, "qualified bytes") }
    after { FileUtils.remove_entry(directory) }

    it "rejects a replaced manifest before package verification" do
      File.write(File.join(directory, "checksums.json"), "{}")
      expect { described_class.verify!(directory) }.to raise_error(described_class::Error, /candidate manifest/)
    end

    it "preserves an identical published artifact without pushing" do
      described_class.publish!([path], fetch: ->(_path) { digest }, push: push)
      expect(push).not_to have_received(:call)
      expect(File.binread(path)).to eq("qualified bytes")
    end

    it "publishes absent bytes and verifies the remote download" do
      responses = [nil, digest]
      described_class.publish!([path], fetch: ->(_path) { responses.shift }, push: push)
      expect(push).to have_received(:call).with(path).once
      expect(File.binread(path)).to eq("qualified bytes")
    end

    it "stops without pushing when existing remote bytes differ" do
      expect { described_class.publish!([path], fetch: ->(_path) { "different" }, push: push) }
        .to raise_error(described_class::Error, /published bytes differ/)
      expect(push).not_to have_received(:call)
    end

    it "stops immediately after a failed push" do
      failed_push = ->(_path) { raise described_class::Error, "gem push failed" }
      expect { described_class.publish!([path, "must-not-be-read"], fetch: ->(_path) {}, push: failed_push) }
        .to raise_error(described_class::Error, /gem push failed/)
    end

    it "stops when a newly published download differs" do
      responses = [nil, "different"]
      expect { described_class.publish!([path, "must-not-be-read"], fetch: ->(_path) { responses.shift }, push: push) }
        .to raise_error(described_class::Error, /download mismatch/)
      expect(push).to have_received(:call).with(path).once
    end
  end
end
