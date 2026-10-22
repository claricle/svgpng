# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "Native RGBA conversion core" do
  it "converts channels and rows with checked bounds and separate buffer ownership" do
    # This developer test builds only the dependency-free pixel core. Installation
    # and rendering never invoke a compiler; PNG encoder integration is pending.
    Dir.mktmpdir("svgpng-rgba") do |directory|
      root = File.expand_path("../native/svgpng_shim", __dir__)
      executable = File.join(directory, "test_rgba")
      output, status = Open3.capture2e(
        "cc", "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic",
        File.join(root, "rgba.c"), File.join(root, "test_rgba.c"), "-o", executable
      )
      expect(status.success?).to be(true), output

      output, status = Open3.capture2e(executable)
      expect(status.success?).to be(true), output
      expect(output).to include("RGBA conversion assertions passed")
    end
  end
end
