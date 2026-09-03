# frozen_string_literal: true

module Yeptris
  # The base error for everything this library raises deliberately.
  class Error < StandardError; end

  # The input is not valid YAML (or valid for the requested mode).
  # message carries the C parser's line/column detail.
  class ParseError < Error; end

  # A handle was used after its document was freed. Raised, never a
  # segfault: the Document is the sole C-memory owner and every Node
  # checks liveness through it.
  class FreedError < Error; end

  # Building a document from a Ruby object graph hit something the
  # builder refuses (cycles, unsupported objects).
  class DumpError < Error; end
end
