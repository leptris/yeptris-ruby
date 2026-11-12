# frozen_string_literal: true

# yeptris#1305: safe_load's permitted-classes gate skipped the
# timestamp family's RESOLVED class. A plain timestamp resolves like
# psych's scanner — date-only to Date, date+time to Time — and psych's
# safe law gates the RESOLVED class: ClassLoader::Restricted#time/#date
# raise DisallowedClass naming Time/Date when that class is not in
# permitted_classes. The old gate fired only when NEITHER Date NOR Time
# was permitted and always named Date, so a [Date]-permitted call
# silently materialized a Time. Every row below is diffed against
# stdlib Psych.

require "yeptris/psych"
require "psych"
require "date"

RSpec.describe "safe_load's timestamp permitted gate (#1305)" do
  FULL = "f: 2024-01-02 10:00:00\n"
  DATE_ONLY = "d: 2024-01-02\n"

  def yep(yaml, permitted)
    Yeptris::Psych.safe_load(yaml, permitted_classes: permitted)
  rescue Yeptris::Psych::DisallowedClass => e
    e.name
  end

  def psy(yaml, permitted)
    ::Psych.safe_load(yaml, permitted_classes: permitted)
  rescue ::Psych::DisallowedClass => e
    # stdlib's DisallowedClass carries no .name reader — the class
    # name rides the message ("Tried to load unspecified class: Time")
    e.message[/unspecified class: (\w+)/, 1]
  end

  it "raises DisallowedClass naming Time when only Date is permitted" do
    expect(yep(FULL, [Date])).to eq("Time")
  end

  it "raises DisallowedClass naming Time with no permissions" do
    expect(yep(FULL, [])).to eq("Time")
  end

  it "loads the full timestamp when Time is permitted" do
    res = yep(FULL, [Time])
    expect(res["f"]).to be_a(::Time)
    expect(res["f"].year).to eq(2024)
  end

  it "raises DisallowedClass naming Date for a date-only scalar when only Time is permitted" do
    expect(yep(DATE_ONLY, [Time])).to eq("Date")
  end

  it "raises DisallowedClass naming Date for a date-only scalar with no permissions" do
    expect(yep(DATE_ONLY, [])).to eq("Date")
  end

  it "loads the date-only scalar when Date is permitted" do
    res = yep(DATE_ONLY, [Date])
    expect(res["d"]).to eq(::Date.new(2024, 1, 2))
  end

  it "gates the explicit timestamp tag by the resolved class" do
    expect(yep("t: !!timestamp 2024-01-02 10:00:00\n", [Date])).to eq("Time")
    expect(yep("t: !!timestamp 2024-01-02\n", [Time])).to eq("Date")
  end

  it "keeps the default face loading (permitted Date+Time)" do
    expect(yep(FULL, [Date, Time])["f"]).to be_a(::Time)
    expect(yep(DATE_ONLY, [Date, Time])["d"]).to eq(::Date.new(2024, 1, 2))
  end

  it "matches stdlib psych across the timestamp matrix" do
    {
      FULL => [[], [Date], [Time], [Date, Time]],
      DATE_ONLY => [[], [Date], [Time], [Date, Time]],
      "t: !!timestamp 2024-01-02 10:00:00\n" => [[], [Date], [Time]],
    }.each do |yaml, perms|
      perms.each do |p|
        expect(yep(yaml, p)).to eq(psy(yaml, p)),
                               "mismatch for #{yaml.inspect} permitted #{p.inspect}: " \
                               "yeptris #{yep(yaml, p).inspect} vs psych #{psy(yaml, p).inspect}"
      end
    end
  end

  it "keeps the marshal fast lane off the timestamp gate (refusal falls to the checked walk)" do
    # a timestamp source carries no gate byte, so walk_safe's slice
    # only stays correct because the marshal builder refuses
    # timestamps — pin the refusal that the gate's correctness rides
    doc = Yeptris::Document.parse(FULL, schema: :compat_11)
    expect(doc.root(0).marshal_fast).to be_nil
    doc.free
  end
end
