/* cbor_ruby.c — CBOR decode → Ruby VALUE in one C pass (#157).
 *
 * The FFI ladder's CBOR.load pays decode + a Marshal emit/load round
 * trip; this walks the decoded DOM directly, building the same VALUEs
 * the materializer builds (tag-driven scalar semantics, insertion-
 * order mappings), with no intermediate representation.
 */
#include <ruby.h>
#include <ruby/encoding.h>
#include <stdlib.h>
#include <string.h>

#include "dom/dom.h"
#include <yeptris/cbor.h>
#include <yeptris/dom.h>
#include <yeptris/resolve.h>

static const char* cr_view(const yep_dom* d, yep_sview sv, uint32_t* len) {
    *len = sv.len;
    if (sv.len == 0) {
        return "";
    }
    return (sv.off & YEP_SV_INPUT) ? (d->str + (sv.off & YEP_SV_OFF)) : (d->input_base + sv.off);
}

static VALUE cr_scalar(const yep_dom* d, const yep_dnode* n) {
    uint32_t len = 0;
    const char* p = cr_view(d, n->value, &len);
    switch (n->tag_id) {
    case YEPTRIS_TAG_NULL:
        return Qnil;
    case YEPTRIS_TAG_BOOL:
        if (len == 1) { /* Psych: "y"/"n" stay Strings */
            return rb_utf8_str_new(p, len);
        }
        return (len == 4 && memcmp(p, "true", 4) == 0) ? Qtrue : Qfalse;
    case YEPTRIS_TAG_INT: {
        char buf[32];
        size_t cp = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
        memcpy(buf, p, cp);
        buf[cp] = '\0';
        char* end = NULL;
        long long v = strtoll(buf, &end, 10);
        if (end != buf && *end == '\0' && end == buf + len && v > INT64_MIN) {
            return LL2NUM(v);
        }
        return rb_utf8_str_new(p, len); /* int_or_string's fallback */
    }
    case YEPTRIS_TAG_FLOAT: {
        char buf[64];
        size_t cp = len < sizeof(buf) - 1 ? len : sizeof(buf) - 1;
        memcpy(buf, p, cp);
        buf[cp] = '\0';
        char* end = NULL;
        double v = strtod(buf, &end);
        if (end != buf && end != buf + len) {
            return rb_utf8_str_new(p, len); /* float_or_string's fallback */
        }
        return DBL2NUM(v);
    }
    default:
        return rb_utf8_str_new(p, len);
    }
}

static VALUE cr_walk(const yep_dom* d, uint32_t id) {
    const yep_dnode* n = &d->nodes[id];
    switch (n->kind) {
    case YEP_DOM_SCALAR:
        return cr_scalar(d, n);
    case YEP_DOM_SEQUENCE: {
        long cnt = (long)n->count;
        VALUE a = rb_ary_new_capa(cnt);
        uint32_t c = n->first_child;
        for (long i = 0; i < cnt && c != UINT32_MAX; i++) {
            rb_ary_push(a, cr_walk(d, c));
            c = d->nodes[c].next_sibling;
        }
        return a;
    }
    case YEP_DOM_MAPPING: {
        long pairs = (long)(n->count / 2);
        VALUE h = rb_hash_new_capa(pairs);
        uint32_t c = n->first_child;
        for (long i = 0; i < pairs && c != UINT32_MAX; i++) {
            VALUE k = cr_walk(d, c);
            c = d->nodes[c].next_sibling;
            VALUE v = (c != UINT32_MAX) ? cr_walk(d, c) : Qnil;
            if (c != UINT32_MAX) {
                c = d->nodes[c].next_sibling;
            }
            rb_hash_aset(h, k, v);
        }
        return h;
    }
    default: /* ALIAS: CBOR decode never produces one */
        return Qnil;
    }
}

VALUE yep_rb_cbor_load(const char* p, size_t len, int strict) {
    YeptrisStatus st = YEPTRIS_OK;
    /* the DOM borrows the input buffer zero-copy; the walk ALLOCATES,
     * and a GC compaction mid-walk moves the caller's String — the
     * borrowed base dangles (the #160 CI bus error on 3.2/linux).
     * Same discipline as the JSON walk: GC off across decode+walk */
    VALUE gc_on = rb_gc_disable();
    yep_dom* d = (yep_dom*)yeptris_cbor_decode(p, len, strict ? YEPTRIS_CBOR_STRICT : 0, &st);
    if (d == NULL) {
        if (RTEST(gc_on)) {
            rb_gc_enable();
        }
        return Qundef;
    }
    VALUE v = (d->dcount > 0 && d->docs[0] != UINT32_MAX) ? cr_walk(d, d->docs[0]) : Qnil;
    yeptris_document_free((YeptrisDocument)d);
    if (RTEST(gc_on)) {
        rb_gc_enable();
    }
    return v;
}
