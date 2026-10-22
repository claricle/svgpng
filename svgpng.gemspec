# frozen_string_literal: true

require_relative "lib/svgpng/version"

Gem::Specification.new do |spec|
  spec.name = "svgpng"
  spec.version = Svgpng::VERSION
  spec.authors = ["Ribose Inc."]
  spec.summary = "Explicit-input SVG to PNG rendering boundary"
  spec.homepage = "https://github.com/claricle/svgpng"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "docs/**/*", "README.adoc"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
