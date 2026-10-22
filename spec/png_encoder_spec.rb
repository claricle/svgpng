# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "Pinned native PNG encoder" do
  [
    [10_658, "0x1320", "svgpng requires libpng 1.6.59"],
    [10_659, "0x1310", "svgpng requires zlib 1.3.2"]
  ].each do |png_version, zlib_version, diagnostic|
    it "rejects incompatible headers with #{diagnostic}" do
      # These version-only mock headers test rejection, never encoding. Full
      # roundtrip/fault assertions live in the explicit native:check_encoder task.
      Dir.mktmpdir("svgpng-version-gate") do |directory|
        File.write(File.join(directory, "png.h"), <<~HEADER)
          #define PNG_LIBPNG_VER #{png_version}
          #define PNG_USER_MEM_SUPPORTED
          #define PNG_SETJMP_SUPPORTED
        HEADER
        File.write(File.join(directory, "zlib.h"), "#define ZLIB_VERNUM #{zlib_version}\n")
        source = File.expand_path("../native/svgpng_shim/encoder.c", __dir__)
        output, result = Open3.capture2e("cc", "-E", "-I", directory, source)
        expect(result.success?).to be(false)
        expect(output).to include(diagnostic)
      end
    end
  end
end
