# frozen_string_literal: true

require "yeptris"

# The README's example blocks are the SSOT — this spec executes them
# verbatim so docs cannot rot silently (a broken example once shipped
# for weeks; inspection missed it, execution caught it).
RSpec.describe "README examples" do
  let(:config_yaml) { "server:\n  port: 8080\n" }

  # encoding: pinned — README.adoc carries UTF-8 prose and a C/POSIX
  # locale defaults the read to US-ASCII, where scan raises (surfaced
  # by the riscv64-linux rehearsal running the suite under LC_ALL=C)
  blocks = File.read(File.expand_path("../README.adoc", __dir__), encoding: "UTF-8")
              .scan(/\[source,ruby\]\n----\n(.*?)----/m).flatten
  raise "no [source,ruby] blocks found in README.adoc" if blocks.empty?

  blocks.each_with_index do |code, i|
    it "block #{i + 1} runs verbatim" do
      eval(code, binding, "README.adoc block #{i + 1}") # rubocop:disable Security/Eval
    end
  end
end
