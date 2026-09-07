/* json_ruby.c — fused RFC 8259 → Ruby VALUE (TODO.restructure/22). */
#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/intern.h>
#include <stdlib.h>
#include <string.h>
#include "parse/scalars.h"
#include "scan/json.h"

#define YEP_JR_MAX 1000
#define YEP_KC 1024

typedef struct {
    uint64_t h;
    uint32_t len;
    VALUE v;
} kcent;

typedef struct {
    const char* p;
    size_t len;
    size_t i;
    char* scratch;
    size_t scratch_cap;
    int depth;
    int err;
    rb_encoding* enc;
    kcent kc[YEP_KC];
} jr;

static VALUE jr_value(jr* j);

static void jr_ws(jr* j) {
    while (j->i < j->len) {
        unsigned char c = (unsigned char)j->p[j->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') j->i++;
        else break;
    }
}

static uint64_t jr_hash(const char* sp, long sl) {
    /* FNV-1a 64 — cheap, good enough for short keys */
    uint64_t h = 14695981039346656037ull;
    for (long i = 0; i < sl; i++) {
        h ^= (unsigned char)sp[i];
        h *= 1099511628211ull;
    }
    h ^= (uint64_t)sl;
    return h;
}

static VALUE jr_cached(jr* j, const char* sp, long sl) {
    uint64_t h = jr_hash(sp, sl);
    uint32_t slot = (uint32_t)(h & (YEP_KC - 1));
    kcent* e = &j->kc[slot];
    if (e->v != 0 && e->h == h && e->len == (uint32_t)sl &&
        (long)RSTRING_LEN(e->v) == sl &&
        memcmp(RSTRING_PTR(e->v), sp, (size_t)sl) == 0) {
        return e->v;
    }
    VALUE s = rb_enc_str_new(sp, sl, j->enc);
    rb_str_freeze(s);
    e->h = h;
    e->len = (uint32_t)sl;
    e->v = s;
    return s;
}

static VALUE jr_str(jr* j, int as_key) {
    size_t start = j->i, close = 0;
    int has_esc = 0;
    if (!yep_json_string(j->p, j->len, &j->i, &close, &has_esc)) { j->err = -2; return Qnil; }
    const char* sp; long sl;
    if (has_esc) {
        uint32_t span = (uint32_t)(close - start - 1);
        if (span + 1 > j->scratch_cap) {
            size_t cap = j->scratch_cap ? j->scratch_cap : 64;
            while (cap < span + 1) cap *= 2;
            char* ns = realloc(j->scratch, cap);
            if (!ns) { j->err = -1; return Qnil; }
            j->scratch = ns; j->scratch_cap = cap;
        }
        sl = (long)yep_finish_double_into(j->p, (uint32_t)(start + 1), (uint32_t)close, j->scratch, span);
        sp = j->scratch;
    } else {
        sp = j->p + start + 1;
        sl = (long)(close - start - 1);
    }
    if (as_key || sl <= 24) return jr_cached(j, sp, sl);
    return rb_enc_str_new(sp, sl, j->enc);
}

static VALUE jr_num(jr* j) {
    size_t start = j->i;
    int shape = 0;
    int64_t iv = 0;
    double dv = 0.0;
    /* the fused kernel (scan/json.h): ONE grammar walk, values out */
    if (!yep_json_number_scan(j->p, j->len, &j->i, &shape, &iv, &dv)) {
        j->err = -2;
        return Qnil;
    }
    if (shape == 0) {
        return LL2NUM(iv);
    }
    if (shape == 1) {
        return DBL2NUM(dv);
    }
    /* integer text beyond int64: exact Bignum from the validated
     * span (JSON.parse's behavior). Absurd lengths degrade to the
     * approximate double. */
    size_t n = j->i - start;
    if (n < 512) {
        char buf[512];
        memcpy(buf, j->p + start, n);
        buf[n] = '\0';
        return rb_cstr_to_inum(buf, 10, TRUE);
    }
    return DBL2NUM(dv);
}

static VALUE jr_object(jr* j) {
    j->i++; j->depth++;
    VALUE h = rb_hash_new_capa(8);
    jr_ws(j);
    if (j->i < j->len && j->p[j->i] == '}') { j->i++; j->depth--; return h; }
    /* pairs collect into a flat buffer and land in ONE bulk insert:
     * rb_hash_bulk_insert skips the per-pair method dispatch the
     * aset loop pays (TODO.restructure/26's margin work) */
    VALUE pairs[64];
    VALUE* pv = pairs;
    size_t pcap = 64, pn = 0, heap_cap = 0;
    for (;;) {
        jr_ws(j);
        if (j->i >= j->len || j->p[j->i] != '"') { j->err = -2; goto out; }
        VALUE key = jr_str(j, 1);
        if (j->err) goto out;
        jr_ws(j);
        if (j->i >= j->len || j->p[j->i] != ':') { j->err = -2; goto out; }
        j->i++;
        VALUE val = jr_value(j);
        if (j->err) goto out;
        if (pn + 2 > pcap) {
            size_t ncap = pcap * 2;
            VALUE* nv = malloc(ncap * sizeof(VALUE));
            if (!nv) { j->err = -1; goto out; }
            memcpy(nv, pv, pn * sizeof(VALUE));
            if (pv != pairs) { free(pv); heap_cap = 1; }
            pv = nv; pcap = ncap;
        }
        pv[pn++] = key;
        pv[pn++] = val;
        jr_ws(j);
        if (j->i >= j->len) { j->err = -2; goto out; }
        if (j->p[j->i] == ',') { j->i++; continue; }
        if (j->p[j->i] == '}') { j->i++; break; }
        j->err = -2; goto out;
    }
    rb_hash_bulk_insert((long)pn, (const VALUE*)pv, h);
out:
    if (pv != pairs) { free(pv); (void)heap_cap; }
    if (j->err) return Qnil;
    j->depth--;
    return h;
}

static VALUE jr_array(jr* j) {
    j->i++; j->depth++;
    VALUE a = rb_ary_new_capa(8);
    jr_ws(j);
    if (j->i < j->len && j->p[j->i] == ']') { j->i++; j->depth--; return a; }
    for (;;) {
        VALUE v = jr_value(j);
        if (j->err) return Qnil;
        rb_ary_push(a, v);
        jr_ws(j);
        if (j->i >= j->len) { j->err = -2; return Qnil; }
        if (j->p[j->i] == ',') { j->i++; continue; }
        if (j->p[j->i] == ']') { j->i++; j->depth--; return a; }
        j->err = -2; return Qnil;
    }
}

static VALUE jr_value(jr* j) {
    if (j->depth >= YEP_JR_MAX) { j->err = -2; return Qnil; }
    jr_ws(j);
    if (j->i >= j->len) { j->err = -2; return Qnil; }
    char c = j->p[j->i];
    if (c == '{') return jr_object(j);
    if (c == '[') return jr_array(j);
    if (c == '"') return jr_str(j, 0);
    if (c == 't') {
        if (!yep_json_literal(j->p, j->len, &j->i, "true")) { j->err = -2; return Qnil; }
        return Qtrue;
    }
    if (c == 'f') {
        if (!yep_json_literal(j->p, j->len, &j->i, "false")) { j->err = -2; return Qnil; }
        return Qfalse;
    }
    if (c == 'n') {
        if (!yep_json_literal(j->p, j->len, &j->i, "null")) { j->err = -2; return Qnil; }
        return Qnil;
    }
    if (c == '-' || (c >= '0' && c <= '9')) return jr_num(j);
    j->err = -2; return Qnil;
}

VALUE yep_rb_parse_json(const char* p, size_t len) {
    jr j;
    memset(&j, 0, sizeof(j));
    j.p = p; j.len = len; j.enc = rb_utf8_encoding();
    VALUE already = rb_gc_disable();
    VALUE v = jr_value(&j);
    jr_ws(&j);
    if (j.i != len && j.err == 0) j.err = -2;
    free(j.scratch);
    if (already == Qfalse) rb_gc_enable();
    if (j.err == -1) rb_raise(rb_eNoMemError, "yeptris native json");
    if (j.err != 0) rb_raise(rb_path2class("Yeptris::ParseError"), "native json parse failed");
    return v;
}
