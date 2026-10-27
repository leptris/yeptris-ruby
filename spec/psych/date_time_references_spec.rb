# frozen_string_literal: true

# The stdlib ports: test_date_time.rb + test_object_references.rb
# (#179's audit). stdlib names, function for function.
RSpec.describe "Psych dates, times, and object references (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  def assert_cycle(obj)
    expect(::Psych.unsafe_load(::Psych.dump(obj))).to eq(obj)
  end

  # --- test_date_time.rb ---
  it "test_usec" do
    assert_cycle(::Time.utc(2017, 4, 13, 12, 0, 0, 5))
  end

  it "test_non_utc" do
    assert_cycle(::Time.new(2017, 4, 13, 12, 0, 0.5, "+09:00"))
  end

  it "test_timezone_offset" do
    times = [::Time.new(2017, 4, 13, 12, 0, 0, "+09:00"),
             ::Time.new(2017, 4, 13, 12, 0, 0, "-05:00")]
    cycled = ::Psych.unsafe_load(::Psych.dump(times))
    expect(cycled.first.to_s).to match(/12:00:00 \+0900/)
    expect(cycled.last.to_s).to match(/12:00:00 -0500/)
  end

  it "test_new_datetime" do
    assert_cycle(::DateTime.new)
  end

  it "test_datetime_non_utc" do
    assert_cycle(::DateTime.new(2017, 4, 13, 12, 0, 0.5, "+09:00"))
  end

  it "test_julian_date" do
    assert_cycle(::Date.new(1582, 10, 4, ::Date::GREGORIAN))
  end

  it "test_proleptic_gregorian_date" do
    assert_cycle(::Date.new(1582, 10, 14, ::Date::GREGORIAN))
  end

  it "test_invalid_date (the string stays a string)" do
    assert_cycle("2013-10-31T10:40:07-000000000000033")
  end

  it "test_string_tag" do
    expect(::Psych.dump(::DateTime.now)).to match(/DateTime/)
  end

  it "test_round_trip" do
    assert_cycle(::DateTime.now)
  end

  it "test_alias_with_time" do
    t = ::Time.now
    yaml = ::Psych.dump({ a: t, b: t })
    expect(yaml).to match(/&/)
    expect(yaml).to match(/\*/)
  end

  # --- test_object_references.rb ---
  def assert_reference_trip(obj)
    yml = ::Psych.dump([obj, obj])
    expect(yml).to match(/\*-?\d+/)
    data = begin
      ::Psych.load(yml)
    rescue ::Psych::DisallowedClass
      ::Psych.unsafe_load(yml)
    end
    expect(data.first).to equal(data.last)
  end

  it "test_datetime_has_references" do
    assert_reference_trip(::DateTime.now)
  end

  it "test_struct_has_references" do
    struct_klass = ::Struct.new(:foo)
    assert_reference_trip(struct_klass.new(1))
  end

  it "test_float_references" do
    data = ::Psych.unsafe_load("---\n- &name 1.2\n- *name\n")
    expect(data.first).to eq(data.last)
    expect(data.first).to equal(data.last)
  end

  it "test_binary_references" do
    data = ::Psych.unsafe_load("---\n- &name !binary |-\n  aGVsbG8gd29ybGQh\n- *name\n")
    expect(data.first).to eq(data.last)
    expect(data.first).to equal(data.last)
  end
end

# Range/Module/Class/Rational/Complex/Data reference trips need
# YAMLTree's visit arms for those classes (#179's object-dump port);
# !ruby/regexp revival likewise. The location-carrying TreeBuilder
# (test_tree_builder.rb) needs the event-location surface on the
# Nodes wrappers — both tracked in #179's list.
RSpec.describe "Psych object references (pending ports)" do
  xit "test_range_has_references" do
  end
  xit "test_regexp_references" do
  end
end
