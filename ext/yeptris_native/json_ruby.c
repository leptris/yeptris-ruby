/* json_ruby.c — fused RFC 8259 → Ruby VALUE (TODO.restructure/22). */
#include <ruby.h>
#include <ruby/encoding.h>
#include <stdlib.h>
#include <string.h>
#include "parse/numbers.h"
#include "parse/scalars.h"
#include "scan/json.h"

#define YEP_JR_MAX 1000
#define YEP_KC 256

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
    if (as_key || sl <= 2) return jr_cached(j, sp, sl);
    return rb_enc_str_new(sp, sl, j->enc);
}

static VALUE jr_num(jr* j) {
    size_t start = j->i;
    if (!yep_json_number(j->p, j->len, &j->i)) { j->err = -2; return Qnil; }
    const char* s = j->p + start;
    uint32_t n = (uint32_t)(j->i - start);
    int is_float = 0, neg = 0;
    uint32_t k = 0;
    if (s[0] == '-') { neg = 1; k = 1; }
    for (; k < n; k++) {
        char c = s[k];
        if (c == '.' || c == 'e' || c == 'E') { is_float = 1; break; }
    }
    if (!is_float && n - (uint32_t)neg <= 18) {
        int64_t v = 0;
        for (k = (uint32_t)neg; k < n; k++) v = v * 10 + (s[k] - '0');
        if (neg) v = -v;
        return LL2NUM(v);
    }
    if (is_float) {
        double d = 0.0;
        if (yep_num_f64(s, n, &d) != 0) { j->err = -2; return Qnil; }
        return DBL2NUM(d);
    }
    int64_t v = 0;
    if (yep_num_i64(s, n, &v) != 0) {
        double d = 0.0;
        if (yep_num_f64(s, n, &d) != 0) { j->err = -2; return Qnil; }
        return DBL2NUM(d);
    }
    return LL2NUM(v);
}

static VALUE jr_object(jr* j) {
    j->i++; j->depth++;
    VALUE h = rb_hash_new_capa(8);
    jr_ws(j);
    if (j->i < j->len && j->p[j->i] == '}') { j->i++; j->depth--; return h; }
    for (;;) {
        jr_ws(j);
        if (j->i >= j->len || j->p[j->i] != '"') { j->err = -2; return Qnil; }
        VALUE key = jr_str(j, 1);
        if (j->err) return Qnil;
        jr_ws(j);
        if (j->i >= j->len || j->p[j->i] != ':') { j->err = -2; return Qnil; }
        j->i++;
        VALUE val = jr_value(j);
        if (j->err) return Qnil;
        rb_hash_aset(h, key, val);
        jr_ws(j);
        if (j->i >= j->len) { j->err = -2; return Qnil; }
        if (j->p[j->i] == ',') { j->i++; continue; }
        if (j->p[j->i] == '}') { j->i++; j->depth--; return h; }
        j->err = -2; return Qnil;
    }
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
