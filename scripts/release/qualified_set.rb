# frozen_string_literal: true

require "json"
require "net/http"
require_relative "../../lib/svgpng/release_set"

module Svgpng
  # Publishes only the immutable, previously qualified 0.1.0 set.
  module QualifiedRelease
    RUN = 40_522_909_868
    ARTIFACT = 12_743_646_083
    SOURCE = "d73eaa45b671efe722ebf07682b248eee0aec79d"
    TREE = "7b7a8ad8b84b465d477453423d794148e10f11b5"
    MANIFEST_SHA = "368d1b3194ba4925b6bdf257562914b0dff9d526e59d54d548a7437ce311bf46"
    RUBY4_JOB = "resolution (x86_64-linux, ubuntu-22.04, false, 4.0) / qualify"
    MANIFEST = File.expand_path("checksums.json", __dir__)
    class Error < StandardError; end

    def self.assert!(condition, message)
      raise Error, message unless condition
    end

    def self.verify_provenance!(run, artifact, jobs, commit)
      assert!(run.values_at("id", "head_sha", "status", "conclusion", "path") ==
        [RUN, SOURCE, "completed", "success", ".github/workflows/native.yml"], "unqualified run")
      %w[repository head_repository].each do |key|
        assert!(run.dig(key, "full_name") == "claricle/svgpng", "wrong qualification repository")
      end
      verify_artifact!(artifact)
      assert!(commit.dig("commit", "tree", "sha") == TREE, "wrong qualified source tree")
      verify_jobs!(jobs)
    end

    def self.verify_artifact!(artifact)
      assert!(artifact.values_at("id", "name", "expired") ==
        [ARTIFACT, "svgpng-0.1.0-eight-gem-candidate-set", false] &&
        artifact.dig("workflow_run", "id") == RUN && artifact.dig("workflow_run", "head_sha") == SOURCE,
              "wrong or expired qualification artifact")
    end

    def self.verify_jobs!(jobs)
      names = jobs.map { |job| job.fetch("name") }
      assert!(jobs.all? { |job| job["conclusion"] == "success" }, "failed qualification jobs")
      verify_job_names!(names)
    end

    def self.verify_job_names!(names)
      assert!(names.length == 16 && names.uniq.length == 16, "incomplete qualification jobs")
      assert!(names.include?("assemble"), "missing assembly qualification")
      assert!(names.include?(RUBY4_JOB), "missing Ruby 4 qualification")
      verify_platform_names!(names.reject { |name| name == RUBY4_JOB })
    end

    def self.verify_platform_names!(names)
      %w[targets resolution].each do |phase|
        ReleaseSet::TARGETS.reject { |target| target == "ruby" }.each do |target|
          assert!(names.one? { |name| name.start_with?("#{phase} (#{target}, ") && name.end_with?(" / qualify") },
                  "missing #{phase} qualification for #{target}")
        end
      end
    end

    def self.verify!(directory)
      assert!(Digest::SHA256.file(MANIFEST).hexdigest == MANIFEST_SHA, "changed approved manifest")
      candidate_manifest = File.join(directory, "checksums.json")
      assert!(!File.symlink?(candidate_manifest) && File.file?(candidate_manifest) &&
        Digest::SHA256.file(candidate_manifest).hexdigest == MANIFEST_SHA, "wrong candidate manifest")
      ReleaseSet.verify!(directory: directory, manifest_path: MANIFEST)
    end

    # A 404 alone means absent. Authentication/network/server failures must stop publication.
    def self.remote_digest(path)
      uri = URI("https://rubygems.org/downloads/#{File.basename(path)}")
      response = Net::HTTP.get_response(uri)
      return nil if response.is_a?(Net::HTTPNotFound)

      assert!(response.is_a?(Net::HTTPSuccess), "RubyGems download failed: #{response.code}")
      Digest::SHA256.hexdigest(response.body)
    end

    def self.publish!(paths, fetch: method(:remote_digest), push: method(:push!))
      paths.each { |path| publish_one!(path, fetch, push) }
    end

    def self.publish_one!(path, fetch, push)
      expected = Digest::SHA256.file(path).hexdigest
      existing = fetch.call(path)
      if existing
        assert!(existing == expected, "published bytes differ: #{File.basename(path)}")
      else
        push.call(path)
        assert!(fetch.call(path) == expected, "published download mismatch: #{File.basename(path)}")
      end
      puts "Verified RubyGems bytes: #{File.basename(path)}"
    end

    def self.push!(path)
      assert!(system("gem", "push", "--host", "https://rubygems.org", path), "gem push failed: #{path}")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command, directory = ARGV
  release = Svgpng::QualifiedRelease
  if command == "provenance"
    data = %w[run artifact jobs commit].map { |name| JSON.parse(File.read(File.join(directory, "#{name}.json"))) }
    release.verify_provenance!(*data)
  else
    release.assert!(%w[verify publish].include?(command), "expected provenance, verify or publish")
    paths = release.verify!(File.expand_path(directory))
    release.publish!(paths) if command == "publish"
    puts "Verified exact eight approved SVGPNG 0.1.0 gems"
  end
end
