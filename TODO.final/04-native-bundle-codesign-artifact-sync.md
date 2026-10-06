# 04 — native-bundle codesign (macOS 14.1+) + artifact/version sync

Status: OPEN. Owner: this binding's owning session. Filed from the
engine-side investigation 2026-10-06 (leptris session); applies to
every `*-ruby` binding that ships prebuilt native artifacts.

## Problem

macOS 14.1+ on Apple Silicon kills unsigned or signature-invalidated
arm64 Mach-O libraries at load (`killed: 9`). CI-built arm64 dylibs
are linker-ad-hoc-signed, but any packaging step that COPIES or
re-compresses the artifact can strip/invalidate the ad-hoc
signature, and a prebuilt gem that installs an unsigned dylib then
fails at `dlopen` on user machines. Nothing in the current
packaging or audit path checks this.

## Work items

1. **Ad-hoc codesign at package time.** For every vendored macOS
   arm64 (and universal) library the gem ships:
   `codesign --force --sign - <lib>` as the LAST packaging step
   (after any copy/strip/recompress), so the signature always
   covers the final bytes. No Apple Developer identity is needed —
   ad-hoc is sufficient for load validation.
2. **Verify in the audit gate.** Extend the existing
   `rake audit` (the vendor-artifact validator: rake compile +
   audit:symbols + CI) with `codesign --verify --strict` per
   macOS library, so a tampered or unsigned artifact FAILS the
   gate instead of a user machine.
3. **Artifact/version sync.** At package time (and in audit),
   assert the vendored library's engine version —
   `<engine>_version()` / the dylib's reported version — equals
   the gem's pinned engine version. This closes the manual-pin
   loop: a half-bumped lockstep release can no longer package.

## Acceptance

- Packaging workflow signs every macOS library it produces.
- Audit fails on (a) an unsigned/tampered macOS library, (b) a
  vendored library whose version != the gem's engine pin.
- A deliberate negative test (unsigned copy) proves both gates.

## Notes

- Vendored artifacts are swapped by CI ONLY (the standing law):
  these gates run inside the packaging/audit workflows, not as
  local shortcuts.
- Source-compiled installs are unaffected: clang ad-hoc signs the
  freshly built extension on the user's machine.
- Engine-side context: leptris/leptris session notes 2026-10-06;
  the item is engine-family-wide (l/t/y bindings carry it too).
