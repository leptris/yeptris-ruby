/* cbor_ruby.c — CBOR decode → Ruby VALUE in one C pass (#157).
 *
 * The FFI ladder's CBOR.load pays decode + a Marshal emit/load round
 * trip; this walks the decoded DOM directly, building the same VALUEs
 * the materializer builds (tag-driven scalar semantics, insertion-
 * order mappings), with no intermediate representation.
 */
#include <ruby.h>
/* rb_hash_new_capa is Ruby 3.2+; older Rubies grow dynamically (the
 * json_ruby.c guard, verbatim). */
#if RUBY_API_VERSION_MAJOR > 3 || (RUBY_API_VERSION_MAJOR == 3 && RUBY_API_VERSION_MINOR >= 2)
#define HASH_NEW_CAPA(n) rb_hash_new_capa(n)
#else
#define HASH_NEW_CAPA(n) rb_hash_new()
#endif
#include <ruby/encoding.h>
#include <stdlib.h>
#include <string.h>

static rb_encoding* cr_utf8_enc;

/* Map keys repeat across records in CBOR corpora; interning shares one
 * VALUE per distinct key (the json_ruby.c on_key pattern, #157). */
static VALUE cr_key_str(const char* p, size_t len) {
    return rb_enc_interned_str(p, (long)len, cr_utf8_enc);
}

#include "cbor/sink.h"
#include "dom/dom.h"
#include "doc.h" /* the public YeptrisDocument wrapper: ->dom */
#include <yeptris/cbor.h>
#include <yeptris/dom.h>
#include <yeptris/resolve.h>

/* ---- the VALUE sink (#157): bytes -> VALUE in ONE pass ----
 *
 * The decode grammar drives; these callbacks build the same VALUEs
 * the old DOM + cr_walk pair produced (verified by the binding's
 * differential suite): nil/true/false by tag, ints via LL2NUM (the
 * INT64_MIN text parity wart kept), floats via DBL2NUM (no
 * text round trip), strings copied utf8 (byte strings today ride the
 * same utf8 String), map keys interned (values never are).
 *
 * GC: the container stack is a Ruby array (every VALUE reachable);
 * the input buffer is read directly, so decode runs with GC disabled
 * (the caller's String may move otherwise — the #160 bus error). */

struct rv_ctx {
    VALUE stack; /* [.., container, (pending-key)?] */
    VALUE root;  /* Qnil until the top item closes */
};

static VALUE rv_top(const struct rv_ctx* c) {
    long n = RARRAY_LEN(c->stack);
    return n > 0 ? rb_ary_entry(c->stack, n - 1) : Qnil;
}

static VALUE rv_attach(struct rv_ctx* c, VALUE v) {
    VALUE top = rv_top(c);
    if (RB_TYPE_P(top, T_ARRAY)) {
        rb_ary_push(top, v);
        return v;
    }
    if (RB_TYPE_P(top, T_HASH)) {
        rb_ary_push(c->stack, v); /* becomes the pending key */
        return v;
    }
    /* a pending key: pop it, land v in the map */
    VALUE k = rb_ary_pop(c->stack);
    VALUE map = rv_top(c);
    if (RB_TYPE_P(map, T_HASH)) {
        rb_hash_aset(map, k, v);
        return v;
    }
    /* the stack emptied: v is the root */
    c->root = v;
    return v;
}

static int rv_text(void* ctx, const char* s, uint32_t n, uint8_t tag_id, int is_key,
                   const char* tag, uint32_t tag_len) {
    (void)tag;
    (void)tag_len;
    struct rv_ctx* c = ctx;
    VALUE v;
    switch (tag_id) {
    case YEPTRIS_TAG_NULL:
        v = Qnil;
        break;
    case YEPTRIS_TAG_BOOL:
        v = (n == 4 && memcmp(s, "true", 4) == 0) ? Qtrue : Qfalse;
        break;
    default: /* rendered text (diagnostics, simple(N), key ints) */
        v = rb_utf8_str_new(s, (long)n);
        break;
    }
    (void)is_key;
    rv_attach(c, v);
    return 1;
}

static int rv_int(void* ctx, int negative, uint64_t mag, int is_key, const char* tag,
                  uint32_t tag_len) {
    (void)tag;
    (void)tag_len;
    struct rv_ctx* c = ctx;
    VALUE v;
    if (negative && mag == (uint64_t)1 << 63) {
        /* parity: the DOM path's strtoll guard renders INT64_MIN a
         * String today; the differential suite pins it */
        v = rb_utf8_str_new("-9223372036854775808", 20);
    } else {
        v = LL2NUM(negative ? -(int64_t)mag : (int64_t)mag);
    }
    rv_attach(c, v);
    return 1;
}

static int rv_float(void* ctx, double dv, int is_key, const char* tag, uint32_t tag_len) {
    (void)is_key;
    (void)tag;
    (void)tag_len;
    rv_attach(ctx, DBL2NUM(dv));
    return 1;
}

static int rv_str(void* ctx, const unsigned char* p, uint32_t n, int borrowed, int is_key,
                  const char* tag, uint32_t tag_len) {
    (void)borrowed;
    (void)tag;
    (void)tag_len;
    struct rv_ctx* c = ctx;
    VALUE v = is_key ? rb_enc_interned_str((const char*)p, (long)n, cr_utf8_enc)
                     : rb_utf8_str_new((const char*)p, (long)n);
    rv_attach(c, v);
    return 1;
}

static int rv_bytes(void* ctx, const unsigned char* p, uint32_t n, int borrowed, int is_key,
                    const char* tag, uint32_t tag_len) {
    /* parity: byte strings ride the same utf8 String today */
    return rv_str(ctx, p, n, borrowed, is_key, tag, tag_len);
}

static int rv_open(void* ctx, int is_map, uint64_t cap, const char* tag, uint32_t tag_len) {
    (void)tag;
    (void)tag_len;
    struct rv_ctx* c = ctx;
    VALUE v;
    if (is_map) {
        v = (cap != UINT64_MAX && cap / 2 <= 4096) ? HASH_NEW_CAPA((long)(cap / 2))
                                                   : rb_hash_new();
    } else {
        v = (cap != UINT64_MAX && cap <= 8192) ? rb_ary_new_capa((long)cap) : rb_ary_new();
    }
    rb_ary_push(c->stack, v);
    return 1;
}

static int rv_close(void* ctx, int is_map) {
    (void)is_map;
    struct rv_ctx* c = ctx;
    VALUE v = rb_ary_pop(c->stack);
    rv_attach(c, v);
    return 1;
}

VALUE yep_rb_cbor_load(const char* p, size_t len, int strict) {
    if (cr_utf8_enc == NULL) {
        cr_utf8_enc = rb_utf8_encoding();
    }
    YeptrisStatus st = YEPTRIS_OK;
    /* the decoder reads the caller's buffer directly; GC off across
     * the pass (a compaction would move the String under p — the
     * #160 bus error) */
    VALUE gc_on = rb_gc_disable();
    struct rv_ctx ctx;
    ctx.stack = rb_ary_new();
    ctx.root = Qnil;
    static const yep_cbor_sink RV_SINK = {
        NULL, rv_text, rv_int, rv_float, rv_str, rv_bytes, rv_open, rv_close,
    };
    yep_cbor_sink sink = RV_SINK;
    sink.ctx = &ctx;
    st = yep_cbor_decode_gen((const unsigned char*)p, len, strict, NULL, &sink);
    if (RTEST(gc_on)) {
        rb_gc_enable();
    }
    if (st != YEPTRIS_OK) {
        return Qundef;
    }
    return ctx.root;
}
