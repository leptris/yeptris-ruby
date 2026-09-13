# TODO.lutaml-model — fast paths for the lutaml-model adapters

lutaml-model already wires YeptrisAdapters for YAML, JSON and
key_value. Binding-side work to cut per-record FFI costs — the
crossing boundary, not the parser, is the remaining bottleneck.

## Items

- `Yeptris::YAML.load_files(paths)` / `load_batch(buffers)` — wraps
  the libyeptris batch API (see libyeptris `TODO.ffi-batch`);
  enumerable of materialized objects.
- Single-crossing materialization for the key_value path: record →
  MappingHash-compatible primitives in one FFI call (no per-key
  getter calls); measure crossings per document before/after.
- yamls (multi-document) parity vs Psych stream under batch load.
- Bench artifact numbers: hydrate 10k small documents through the
  lutaml-model YAML adapter, before vs after.

## Depends

- libyeptris `TODO.ffi-batch` (C batch API).

## JSON gate re-baseline (2026-09-13, #74 investigation)

The ubuntu `disable/bulk` gate moved from <1.00 to a reproducible
~1.10-1.14x mean with NO code change on either side: the isolation
run (PR #75) failed against C v0.2.0 — the same tag that was green
at 11:07 — and the ungated same-config leg measured 1.135x in a run
whose gated leg PASSED. The runner image updated mid-day (Node 24
rollout note in the logs) and its stdlib JSON.parse is faster;
yeptris JSON.load on ubuntu is now ~1.1x mean against the new
baseline, bimodal ±0.1 across the runner population.

Actions taken: the ubuntu gate holds the no-regression line at 1.20
with this evidence recorded inline; restoring 1.00 is the JSON tape
route's (yeptris#85) Ruby-side delivery.
