# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rspec", "~> 3.13"
gem "rake", "~> 13.0"
gem "shellwords"
gem "benchmark" # default gem through Ruby 3.x; spec/native_spec.rb needs it on 4.0
gem "cbor"
# the dump-lane float contract (#651) is the fpconv shortest shape —
# json < 2.10 prints Float#to_s bytes (1.0e-07 vs 0.0000001) and the
# parity specs must judge against the line the engine matches. Pinned
# to the 2.10 line (not >=, which resolves json 3.x): 3.x is also a
# FASTER parser, and the JSON profile's GATE ratio is calibrated
# against the 2.x parse baseline — 3.x tripped it at 1.512x
gem "json", "~> 2.10"
