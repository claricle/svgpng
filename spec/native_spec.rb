# frozen_string_literal: true

require "spec_helper"
require "svgpng/native"
require "tmpdir"
require "open3"
require "rbconfig"

RSpec.describe Svgpng::Native do
  before(:context) do
    @directory = File.realpath(Dir.mktmpdir("svgpng-native-spec"))
    @library_path = File.join(@directory, "svgpng.#{RbConfig::CONFIG["DLEXT"]}")
    source = File.expand_path("../native/svgpng_shim/rgba.c", __dir__)
    shared_flag = RUBY_PLATFORM.include?("darwin") ? "-dynamiclib" : "-shared"
    output, status = Open3.capture2e("cc", shared_flag, "-fPIC", "-Wall", "-Wextra", "-Werror",
                                     source, "-o", @library_path)
    raise "Owned RGBA fixture compilation failed: #{output}" unless status.success?
  end

  after(:context) do
    FileUtils.remove_entry(@directory) if @directory
  end

  let(:library_path) { @library_path }
  let(:library) { described_class.load }

  before do
    allow(described_class).to receive(:packaged_library_path).and_return(library_path)
  end

  it "does not open a shared library while requiring the API and binding" do
    script = <<~RUBY
      require "svgpng"
      require "fiddle"
      class << Fiddle::Handle
        def new(*)
          raise "unexpected dlopen"
        end
      end
      require "svgpng/native"
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script)
    expect(status.success?).to be(true), output
  end

  it "derives the sole library location from the current gem and local platform" do
    allow(described_class).to receive(:packaged_library_path).and_call_original
    allow(Gem::Platform).to receive(:local).and_return(Gem::Platform.new("arm64-darwin25"))
    expected = File.join(File.realpath(File.expand_path("../lib/svgpng", __dir__)), "native",
                         "arm64-darwin", "svgpng.dylib")
    expect(described_class.send(:packaged_library_path)).to eq(expected)
    expect(described_class.method(:load).arity).to eq(0)
  end

  it "selects distinct canonical glibc and musl artifacts and only exact Windows UCRT" do
    allow(described_class).to receive(:packaged_library_path).and_call_original
    { "x86_64-linux" => "x86_64-linux/svgpng.so", "x86_64-linux-gnu" => "x86_64-linux/svgpng.so",
      "x86_64-linux-musl" => "x86_64-linux-musl/svgpng.so",
      "aarch64-linux-musl" => "aarch64-linux-musl/svgpng.so",
      "x64-mingw-ucrt" => "x64-mingw-ucrt/svgpng.dll" }.each do |local, suffix|
      allow(Gem::Platform).to receive(:local).and_return(Gem::Platform.new(local))
      expect(described_class.send(:packaged_library_path)).to end_with("/native/#{suffix}")
    end
    %w[x86_64-linux-musleabi x64-mingw32].each do |local|
      allow(Gem::Platform).to receive(:local).and_return(Gem::Platform.new(local))
      expect { described_class.load }.to raise_error(Svgpng::UnsupportedPlatformError)
    end
  end

  it "rejects unsupported platforms before opening any library" do
    allow(described_class).to receive(:packaged_library_path).and_call_original
    allow(Gem::Platform).to receive(:local).and_return(Gem::Platform.new("riscv64-linux"))
    expect(Fiddle::Handle).not_to receive(:new)
    expect { described_class.load }.to raise_error(Svgpng::UnsupportedPlatformError) do |error|
      expect(error.platform).to eq("riscv64-linux")
      expect(error.supported_targets).to eq(described_class::SUPPORTED_TARGETS)
    end
  end

  context "when the packaged artifact is missing" do
    let(:library_path) { File.join(@directory, "absent.so") }

    it "raises the shell's unsupported-platform error without ambient fallback" do
      expect(Fiddle::Handle).not_to receive(:new)
      expect { library }.to raise_error(Svgpng::UnsupportedPlatformError)
    end
  end

  it "rejects symlink artifacts and symlink directory traversal" do
    link = File.join(@directory, "link.so")
    File.symlink(@library_path, link)
    allow(described_class).to receive(:packaged_library_path).and_return(link)
    expect { library }.to raise_error(Svgpng::UnsupportedPlatformError)
    directory_link = File.join(@directory, "linked-directory")
    File.symlink(@directory, directory_link)
    linked_path = File.join(directory_link, File.basename(@library_path))
    allow(described_class).to receive(:packaged_library_path).and_return(linked_path)
    expect { described_class.load }.to raise_error(Svgpng::UnsupportedPlatformError)
  end

  it "maps malformed libraries and missing ABI symbols to NativeError" do
    invalid_path = File.join(@directory, "invalid.so")
    File.binwrite(invalid_path, "not a shared library")
    allow(described_class).to receive(:packaged_library_path).and_return(invalid_path)
    expect { library }.to raise_error(Svgpng::NativeError, /RGBA ABI/)
    allow(described_class).to receive(:packaged_library_path).and_return(@library_path)
    handle = instance_double(Fiddle::Handle)
    allow(Fiddle::Handle).to receive(:new).and_return(handle)
    allow(handle).to receive(:[]).with("svgpng_v1_rgba_to_straight").and_raise(Fiddle::DLError, "missing symbol")
    expect { described_class.load }.to raise_error(Svgpng::NativeError, /missing symbol/)
  end

  it "normalizes zero alpha, rounds low alpha, clamps channels, and preserves opaque pixels" do
    source = [255, 99, 1, 0, 1, 0, 1, 2, 255, 128, 3, 128, 1, 2, 3, 255].pack("C*")
    original = source.dup
    result = library.rgba_to_straight(source, width: 4, height: 1)
    expect(result.bytes).to eq([0, 0, 0, 0, 128, 0, 128, 2, 255, 255, 6, 128, 1, 2, 3, 255])
    expect(result.encoding).to eq(Encoding::BINARY)
    expect(source).to eq(original)
    expect(result).not_to equal(source)
    result.setbyte(0, 42)
    expect(source).to eq(original)
  end

  it "preserves row order with distinct strides and zero-fills destination padding" do
    source = [1, 2, 3, 255, 99, 98, 4, 5, 6, 255, 97, 96].pack("C*").freeze
    result = library.rgba_to_straight(source, width: 1, height: 2, source_stride: 6, destination_stride: 8)
    expect(result.bytes).to eq([1, 2, 3, 255, 0, 0, 0, 0, 4, 5, 6, 255, 0, 0, 0, 0])
    expect(source.bytes).to eq([1, 2, 3, 255, 99, 98, 4, 5, 6, 255, 97, 96])
  end

  it "rejects invalid source bytes, dimensions, strides, and insufficient capacities before allocation" do
    function = library.instance_variable_get(:@convert)
    expect(function).not_to receive(:call)
    expect(Fiddle::Pointer).not_to receive(:malloc)
    [nil, [], true].each do |source|
      expect { library.rgba_to_straight(source, width: 1, height: 1) }.to raise_error(Svgpng::InputError)
    end
    [nil, true, false, 0, -1, 1.5, "1"].each do |value|
      expect { library.rgba_to_straight("1234", width: value, height: 1) }.to raise_error(Svgpng::InputError)
      expect { library.rgba_to_straight("1234", width: 1, height: value) }.to raise_error(Svgpng::InputError)
    end
    [true, false, 0, -1, 1.5, "4"].each do |value|
      expect do
        library.rgba_to_straight("1234", width: 1, height: 1, source_stride: value)
      end.to raise_error(Svgpng::InputError)
      expect do
        library.rgba_to_straight("1234", width: 1, height: 1, destination_stride: value)
      end.to raise_error(Svgpng::InputError)
    end
    expect { library.rgba_to_straight("1234", width: 1, height: 1, source_stride: 3) }.to raise_error(Svgpng::InputError)
    expect { library.rgba_to_straight("1234", width: 1, height: 1, destination_stride: 3) }.to raise_error(Svgpng::InputError)
    expect { library.rgba_to_straight("123", width: 1, height: 1) }.to raise_error(Svgpng::InputError)
    expect { library.rgba_to_straight("1234", width: 1, height: 1, source_stride: 5) }.to raise_error(Svgpng::InputError)
  end

  it "checks size_t arithmetic and configured dimensions, pixel count, and buffers before allocation" do
    expect(Fiddle::Pointer).not_to receive(:malloc)
    expect { library.rgba_to_straight("", width: 32_769, height: 1) }.to raise_error(Svgpng::LimitError)
    expect { library.rgba_to_straight("", width: 8001, height: 8000) }.to raise_error(Svgpng::LimitError)
    expect do
      library.rgba_to_straight("", width: 1, height: 1, source_stride: described_class::Library::SIZE_MAX + 1)
    end.to raise_error(Svgpng::LimitError)
    expect do
      library.rgba_to_straight("", width: 1, height: 2, destination_stride: described_class::Library::SIZE_MAX)
    end.to raise_error(Svgpng::LimitError)
    expect do
      library.rgba_to_straight("", width: 1, height: 1, destination_stride: Svgpng::RenderProfile::MAX_BUFFER_BYTES + 1)
    end.to raise_error(Svgpng::LimitError)
  end

  it "maps every defined native status and rejects unknown statuses" do
    function = library.instance_variable_get(:@convert)
    { 1 => Svgpng::InputError, 2 => Svgpng::LimitError, 3 => Svgpng::LimitError,
      4 => Svgpng::InputError, 5 => Svgpng::InputError, 99 => Svgpng::NativeError }.each do |status, error|
      allow(function).to receive(:call).and_return(status)
      expect { library.rgba_to_straight("1234", width: 1, height: 1) }.to raise_error(error)
    end
  end

  it "releases both caller-owned native buffers even when conversion fails" do
    pointers = []
    allow(Fiddle::Pointer).to receive(:malloc).and_wrap_original do |method, *args|
      method.call(*args).tap { |pointer| pointers << pointer }
    end
    allow(library.instance_variable_get(:@convert)).to receive(:call).and_return(1)
    expect { library.rgba_to_straight("1234", width: 1, height: 1) }.to raise_error(Svgpng::InputError)
    expect(pointers.size).to eq(2)
    expect(pointers).to all(be_freed)
  end

  it "loads RGBA-only libraries and reports the absent encoder ABI only when encoding" do
    expect(library.rgba_to_straight("1234", width: 1, height: 1)).to be_a(String)
    expect { library.encode_rgba("1234", width: 1, height: 1) }.to raise_error(Svgpng::NativeError, /encoder ABI/)
  end

  context "with an encoder ABI ownership fixture, without the real PNG dependencies" do
    before(:context) do
      fixture = File.join(@directory, "encoder_fixture.c")
      @encoder_path = File.join(@directory, "encoder_fixture.#{RbConfig::CONFIG["DLEXT"]}")
      File.write(fixture, <<~C)
        #include "encoder.h"
        #include <stdlib.h>
        #include <string.h>
        static int mode = 0;
        static int releases = 0;
        void fixture_mode(int value) { mode = value; releases = 0; }
        int fixture_releases(void) { return releases; }
        svgpng_v1_png_status svgpng_v1_png_encode(const uint8_t *source, size_t source_length,
            size_t source_stride, size_t width, size_t height, svgpng_v1_png_output *output) {
          if (!source || source_length < source_stride * height || width == 0 || height == 0 ||
              output->bytes != NULL || output->length != 0) return SVGPNG_V1_PNG_INVALID_ARGUMENT;
          output->bytes = malloc(4);
          if (!output->bytes) return SVGPNG_V1_PNG_ALLOCATION_FAILED;
          memcpy(output->bytes, "PNG!", 4);
          output->length = 4;
          if (mode == 10) { free(output->bytes); output->bytes = NULL; }
          if (mode == 11) output->length = 0;
          if (mode == 12) output->length = 268435457;
          if (mode == 13) { free(output->bytes); output->bytes = (uint8_t *)UINTPTR_MAX; }
          return (svgpng_v1_png_status)(mode >= 10 && mode <= 13 ? 0 : mode);
        }
        void svgpng_v1_png_free(svgpng_v1_png_output *output) {
          releases++;
          if (output && output->bytes != (uint8_t *)UINTPTR_MAX) free(output->bytes);
          if (output) { output->bytes = NULL; output->length = 0; }
        }
      C
      native = File.expand_path("../native/svgpng_shim", __dir__)
      shared_flag = RUBY_PLATFORM.include?("darwin") ? "-dynamiclib" : "-shared"
      output, status = Open3.capture2e("cc", shared_flag, "-fPIC", "-Wall", "-Wextra", "-Werror",
                                       "-I", native, File.join(native, "rgba.c"), fixture, "-o", @encoder_path)
      raise "Encoder ABI fixture compilation failed: #{output}" unless status.success?
    end

    let(:library_path) { @encoder_path }
    let(:fixture_handle) { Fiddle::Handle.new(@encoder_path) }
    let(:set_mode) { Fiddle::Function.new(fixture_handle["fixture_mode"], [Fiddle::TYPE_INT], Fiddle::TYPE_VOID) }
    let(:releases) { Fiddle::Function.new(fixture_handle["fixture_releases"], [], Fiddle::TYPE_INT) }

    before { set_mode.call(0) }

    it "copies shim-owned output before releasing it and preserves source including row padding" do
      source = "1234xx5678yy".b.freeze
      result = library.encode_rgba(source, width: 1, height: 2, source_stride: 6)
      expect(result).to eq("PNG!")
      expect(result.encoding).to eq(Encoding::BINARY)
      expect(releases.call).to eq(1)
      expect(source).to eq("1234xx5678yy")
      result.setbyte(0, 0)
      expect(library.encode_rgba("1234", width: 1, height: 1)).to eq("PNG!")
      expect(releases.call).to eq(2)
    end

    it "maps native encoder errors and releases output even when the fixture violates error ownership" do
      { 1 => Svgpng::InputError, 2 => Svgpng::LimitError, 3 => Svgpng::LimitError,
        4 => Svgpng::InputError, 5 => Svgpng::EncodingError, 6 => Svgpng::EncodingError,
        7 => Svgpng::NativeError, 99 => Svgpng::NativeError }.each do |status, error|
        set_mode.call(status)
        expect { library.encode_rgba("1234", width: 1, height: 1) }.to raise_error(error)
        expect(releases.call).to eq(1)
      end
    end

    it "rejects null, empty, oversized, and overflowing outputs before copying and still releases them" do
      { 10 => Svgpng::NativeError, 11 => Svgpng::NativeError,
        12 => Svgpng::LimitError, 13 => Svgpng::NativeError }.each do |mode, error|
        set_mode.call(mode)
        expect { library.encode_rgba("1234", width: 1, height: 1) }.to raise_error(error)
        expect(releases.call).to eq(1)
      end
    end

    it "validates encoder input before allocating or calling the shim" do
      expect(Fiddle::Pointer).not_to receive(:malloc)
      expect { library.encode_rgba("123", width: 1, height: 1) }.to raise_error(Svgpng::InputError)
      expect { library.encode_rgba("1234", width: 1, height: 1, source_stride: false) }.to raise_error(Svgpng::InputError)
      expect { library.encode_rgba("", width: 32_769, height: 1) }.to raise_error(Svgpng::LimitError)
      expect(releases.call).to eq(0)
    end

    it "releases shim output before the Ruby struct and input buffers on a copy failure" do
      pointers = []
      output = nil
      allow(described_class::Library::PNG_OUTPUT).to receive(:malloc).and_wrap_original do |method, *args|
        output = method.call(*args)
      end
      allow(Fiddle::Pointer).to receive(:malloc).and_wrap_original do |method, *args|
        method.call(*args).tap { |pointer| pointers << pointer }
      end
      release = library.send(:encoder_functions).last
      allow(release).to receive(:call).and_wrap_original do |method, *args|
        expect(output.to_ptr).not_to be_freed
        expect(pointers).to all(satisfy { |pointer| !pointer.freed? })
        method.call(*args)
      end
      allow(library).to receive(:copy_png).and_raise(Svgpng::NativeError, "copy failed")
      expect { library.encode_rgba("1234", width: 1, height: 1) }.to raise_error(Svgpng::NativeError, /copy failed/)
      expect(releases.call).to eq(1)
      expect(output.to_ptr).to be_freed
      expect(pointers.last).to be_freed
    end
  end
end
