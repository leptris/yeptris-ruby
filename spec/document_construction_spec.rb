# frozen_string_literal: true

require "spec_helper"

# The Document constructor is an FFI-boundary surface: its pointer
# comes from the C parse/create calls, and the finalizer guard probes
# it with FFI::Pointer#null?. A bare Yeptris::Document.new (the nil
# default) died there with `NoMethodError: undefined method 'null?'
# for nil` — an engine-shaped crash for what is an API misuse. The
# constructor now names the real entry points instead.
RSpec.describe "Yeptris::Document construction" do
  it "raises a guided ArgumentError for a missing document pointer" do
    expect {
      ::Yeptris::Document.new
    }.to raise_error(
      ::ArgumentError,
      /a document FFI pointer is required.*Document\.parse.*Document\.create/m,
    )
  end

  it "raises the guided ArgumentError for a non-pointer argument" do
    expect { ::Yeptris::Document.new("not a pointer") }.to raise_error(::ArgumentError)
    expect { ::Yeptris::Document.new(42) }.to raise_error(::ArgumentError)
  end

  it "still constructs from parse and create (the pointer paths)" do
    d = ::Yeptris::Document.parse("- one: 1\n", schema: :compat_11)
    expect(d).to be_an(::Yeptris::Document)
    expect(d.freed?).to be(false)
    d.free

    empty = ::Yeptris::Document.create
    expect(empty).to be_an(::Yeptris::Document)
    empty.free
  end

  it "still constructs from the wrap and without_finalizer factories" do
    ptr = ::Yeptris::FFI.yeptris_document_new
    begin
      wrapped = ::Yeptris::Document.wrap(ptr)
      expect(wrapped.c_ptr).to eq(ptr)
    ensure
      wrapped&.free
    end

    ptr2 = ::Yeptris::FFI.yeptris_document_new
    begin
      borrowed = ::Yeptris::Document.without_finalizer(ptr2)
      expect(borrowed.c_ptr).to eq(ptr2)
    ensure
      borrowed&.free
    end
  end
end
