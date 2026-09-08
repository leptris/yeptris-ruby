/* yeptris_native.c — Ruby C-API materializer over libyeptris visit
 * (TODO.restructure/22). One Ruby→C call builds the whole object
 * graph via rb_hash_new / rb_ary_push / rb_str_new_len — the same
 * shape as JSON.parse, so the binding can beat it on the fused JSON
 * path. The extension is optional: LoadError falls back to the FFI
 * Marshal ladder. */

#include <ruby.h>
#include <ruby/encoding.h>

#include <stdlib.h>
#include <string.h>

#include <yeptris/api.h>
#include <yeptris/error.h>
#include <yeptris/resolve.h>
#include <yeptris/visit.h>

#define YEP_RB_MAX_DEPTH 1024

static rb_encoding* utf8_enc;

typedef struct {
    VALUE stack[YEP_RB_MAX_DEPTH];
    VALUE keys[YEP_RB_MAX_DEPTH]; /* pending map key at this depth */
    int is_map[YEP_RB_MAX_DEPTH];
    int sp;
    VALUE root;
    VALUE anchors; /* Hash name=>object for YAML identity */
    VALUE pending_anchor; /* String name awaiting the next value */
    int failed;
} rb_ctx;

static void rb_fail(rb_ctx* c) {
    c->failed = 1;
}

static int rb_push_value(rb_ctx* c, VALUE v) {
    if (c->failed) {
        return -1;
    }
    /* bind pending anchor */
    if (!NIL_P(c->pending_anchor) && !NIL_P(c->anchors)) {
        rb_hash_aset(c->anchors, c->pending_anchor, v);
        c->pending_anchor = Qnil;
    }
    if (c->sp == 0) {
        c->root = v;
        return 0;
    }
    VALUE parent = c->stack[c->sp - 1];
    if (c->is_map[c->sp - 1]) {
        VALUE key = c->keys[c->sp - 1];
        if (NIL_P(key)) {
            rb_fail(c);
            return -1;
        }
        rb_hash_aset(parent, key, v);
        c->keys[c->sp - 1] = Qnil;
    } else {
        rb_ary_push(parent, v);
    }
    return 0;
}

static int on_null(void* ctx) {
    return rb_push_value((rb_ctx*)ctx, Qnil);
}

static int on_bool(void* ctx, int truthy) {
    return rb_push_value((rb_ctx*)ctx, truthy ? Qtrue : Qfalse);
}

static int on_int(void* ctx, int64_t v) {
    return rb_push_value((rb_ctx*)ctx, LL2NUM(v));
}

static int on_float(void* ctx, double v) {
    return rb_push_value((rb_ctx*)ctx, DBL2NUM(v));
}

static rb_encoding* utf8_enc;

static VALUE rb_utf8_str(const char* p, size_t len) {
    return rb_enc_str_new(p, (long)len, utf8_enc);
}

/* One-shot interned string (no intermediate alloc) — keys and the
 * short repeated values ("a"/"b"/…) share one VALUE. */
static VALUE rb_utf8_interned(const char* p, size_t len) {
    return rb_enc_interned_str(p, (long)len, utf8_enc);
}

static int on_string(void* ctx, const char* p, size_t len) {
    rb_ctx* c = (rb_ctx*)ctx;
    /* short strings are almost always repeated tokens in JSON corpora;
     * intern them. Longer payloads stay unique. */
    VALUE s = (len <= 16) ? rb_utf8_interned(p, len) : rb_utf8_str(p, len);
    return rb_push_value(c, s);
}

static int on_key(void* ctx, const char* p, size_t len) {
    rb_ctx* c = (rb_ctx*)ctx;
    if (c->sp == 0 || !c->is_map[c->sp - 1]) {
        rb_fail(c);
        return -1;
    }
    c->keys[c->sp - 1] = rb_utf8_interned(p, len);
    return 0;
}

static int on_seq_start(void* ctx) {
    rb_ctx* c = (rb_ctx*)ctx;
    if (c->failed || c->sp >= YEP_RB_MAX_DEPTH) {
        rb_fail(c);
        return -1;
    }
    VALUE a = rb_ary_new();
    /* bind anchor to the container before placing it */
    if (!NIL_P(c->pending_anchor) && !NIL_P(c->anchors)) {
        rb_hash_aset(c->anchors, c->pending_anchor, a);
        c->pending_anchor = Qnil;
    }
    if (c->sp == 0) {
        c->root = a;
    } else {
        VALUE parent = c->stack[c->sp - 1];
        if (c->is_map[c->sp - 1]) {
            VALUE key = c->keys[c->sp - 1];
            if (NIL_P(key)) {
                rb_fail(c);
                return -1;
            }
            rb_hash_aset(parent, key, a);
            c->keys[c->sp - 1] = Qnil;
        } else {
            rb_ary_push(parent, a);
        }
    }
    c->stack[c->sp] = a;
    c->is_map[c->sp] = 0;
    c->keys[c->sp] = Qnil;
    c->sp++;
    return 0;
}

static int on_seq_end(void* ctx) {
    rb_ctx* c = (rb_ctx*)ctx;
    if (c->sp <= 0) {
        rb_fail(c);
        return -1;
    }
    c->sp--;
    return 0;
}

static int on_map_start(void* ctx) {
    rb_ctx* c = (rb_ctx*)ctx;
    if (c->failed || c->sp >= YEP_RB_MAX_DEPTH) {
        rb_fail(c);
        return -1;
    }
    VALUE h = rb_hash_new();
    if (!NIL_P(c->pending_anchor) && !NIL_P(c->anchors)) {
        rb_hash_aset(c->anchors, c->pending_anchor, h);
        c->pending_anchor = Qnil;
    }
    if (c->sp == 0) {
        c->root = h;
    } else {
        VALUE parent = c->stack[c->sp - 1];
        if (c->is_map[c->sp - 1]) {
            VALUE key = c->keys[c->sp - 1];
            if (NIL_P(key)) {
                rb_fail(c);
                return -1;
            }
            rb_hash_aset(parent, key, h);
            c->keys[c->sp - 1] = Qnil;
        } else {
            rb_ary_push(parent, h);
        }
    }
    c->stack[c->sp] = h;
    c->is_map[c->sp] = 1;
    c->keys[c->sp] = Qnil;
    c->sp++;
    return 0;
}

static int on_map_end(void* ctx) {
    rb_ctx* c = (rb_ctx*)ctx;
    if (c->sp <= 0) {
        rb_fail(c);
        return -1;
    }
    c->sp--;
    return 0;
}

static int on_anchor(void* ctx, const char* name, size_t len) {
    rb_ctx* c = (rb_ctx*)ctx;
    c->pending_anchor = rb_utf8_str(name, len);
    return 0;
}

static int on_alias(void* ctx, const char* name, size_t len) {
    rb_ctx* c = (rb_ctx*)ctx;
    VALUE key = rb_utf8_str(name, len);
    VALUE v = rb_hash_lookup2(c->anchors, key, Qundef);
    if (v == Qundef) {
        v = Qnil;
    }
    return rb_push_value(c, v);
}

static int on_doc(void* ctx) {
    /* multi-doc: for load_all we'd collect; single-load takes first.
     * reset root so subsequent docs replace — load_stream uses a
     * different entry that accumulates. */
    (void)ctx;
    return 0;
}

static const YeptrisVisitVTable k_vt = {
    on_null, on_bool, on_int, on_float, on_string,
    on_seq_start, on_seq_end, on_map_start, on_map_end,
    on_key, on_doc, on_anchor, on_alias,
};

/* fused JSON→Ruby (json_ruby.c) — no vtable, beats JSON.parse */
VALUE yep_rb_parse_json(const char* p, size_t len, int strict_dup);

static VALUE ctx_result(rb_ctx* c, YeptrisStatus st) {
    if (st != YEPTRIS_OK || c->failed) {
        if (st == YEPTRIS_ERROR_PARSE) {
            rb_raise(rb_path2class("Yeptris::ParseError"), "native parse failed");
        }
        if (st == YEPTRIS_ERROR_MEMORY) {
            rb_raise(rb_eNoMemError, "yeptris native");
        }
        rb_raise(rb_path2class("Yeptris::Error"), "native materialize failed (%d)", (int)st);
    }
    return c->root;
}

static VALUE native_load_json(int argc, VALUE* argv, VALUE self) {
    (void)self;
    VALUE input, strict;
    rb_scan_args(argc, argv, "11", &input, &strict);
    StringValue(input);
    return yep_rb_parse_json(RSTRING_PTR(input), (size_t)RSTRING_LEN(input), RTEST(strict));
}

static VALUE native_load(VALUE self, VALUE input, VALUE schema) {
    (void)self;
    StringValue(input);
    int sch = YEPTRIS_SCHEMA_11_COMPAT;
    if (!NIL_P(schema)) {
        Check_Type(schema, T_SYMBOL);
        if (rb_sym2id(schema) == rb_intern("core_12")) {
            sch = YEPTRIS_SCHEMA_12_CORE;
        }
    }
    rb_ctx c;
    memset(&c, 0, sizeof(c));
    c.root = Qnil;
    c.pending_anchor = Qnil;
    c.anchors = rb_hash_new();
    VALUE already = rb_gc_disable();
    YeptrisStatus st = yeptris_visit(RSTRING_PTR(input), (size_t)RSTRING_LEN(input),
                                     (YeptrisSchema)sch, &k_vt, &c);
    if (already == Qfalse) {
        rb_gc_enable();
    }
    return ctx_result(&c, st);
}

/* load_stream: accumulate documents into an Array. */
typedef struct {
    rb_ctx inner;
    VALUE docs;
    int in_doc;
} rb_stream_ctx;

static int stream_on_doc(void* ctx) {
    rb_stream_ctx* s = (rb_stream_ctx*)ctx;
    if (s->in_doc && !NIL_P(s->inner.root)) {
        rb_ary_push(s->docs, s->inner.root);
    }
    s->inner.root = Qnil;
    s->inner.sp = 0;
    s->in_doc = 1;
    return 0;
}

static VALUE native_load_stream(VALUE self, VALUE input, VALUE schema) {
    (void)self;
    StringValue(input);
    int sch = YEPTRIS_SCHEMA_11_COMPAT;
    if (!NIL_P(schema) && rb_sym2id(schema) == rb_intern("core_12")) {
        sch = YEPTRIS_SCHEMA_12_CORE;
    }
    rb_stream_ctx s;
    memset(&s, 0, sizeof(s));
    s.inner.root = Qnil;
    s.inner.pending_anchor = Qnil;
    s.inner.anchors = rb_hash_new();
    s.docs = rb_ary_new();
    YeptrisVisitVTable vt = k_vt;
    vt.on_doc = stream_on_doc;
    /* trick: the ctx for scalar callbacks is &s.inner, but on_doc needs
     * &s. Use a unified ctx — rebind all callbacks to take stream ctx
     * by making inner the first field (already is). on_doc uses outer;
     * others use inner via same pointer since inner is first field. */
    YeptrisStatus st = yeptris_visit(RSTRING_PTR(input), (size_t)RSTRING_LEN(input),
                                     (YeptrisSchema)sch, &vt, &s);
    if (st == YEPTRIS_OK && !s.inner.failed) {
        if (!NIL_P(s.inner.root) || s.in_doc) {
            rb_ary_push(s.docs, s.inner.root);
        }
        return s.docs;
    }
    return ctx_result(&s.inner, st == YEPTRIS_OK ? YEPTRIS_ERROR_INTERNAL : st);
}

/* GC-strategy surface (TODO.restructure/34): ENV at load sets the
 * default; the setter re-picks at runtime so the CI referee can A/B
 * in-process. Symbols: :disable, :none, :start. */
extern int yep_rb_gc_mode(void);
extern void yep_rb_set_gc_mode(int mode);
extern int yep_rb_ins_mode(void);
extern void yep_rb_set_ins_mode(int mode);
extern int yep_rb_cache_mode(void);
extern void yep_rb_set_cache_mode(int mode);
extern int yep_rb_shape_mode(void);
extern void yep_rb_set_shape_mode(int mode);
extern double yep_rb_scan_time(const char* p, size_t len, int n);

static VALUE native_gc_mode(VALUE self) {
    (void)self;
    switch (yep_rb_gc_mode()) {
    case 1: return ID2SYM(rb_intern("none"));
    case 2: return ID2SYM(rb_intern("start"));
    default: return ID2SYM(rb_intern("disable"));
    }
}

static VALUE native_ins_mode(VALUE self) {
    (void)self;
    return yep_rb_ins_mode() == 1 ? ID2SYM(rb_intern("aset")) : ID2SYM(rb_intern("bulk"));
}

static VALUE native_ins_mode_set(VALUE self, VALUE mode) {
    (void)self;
    Check_Type(mode, T_SYMBOL);
    ID id = rb_sym2id(mode);
    if (id == rb_intern("bulk")) yep_rb_set_ins_mode(0);
    else if (id == rb_intern("aset")) yep_rb_set_ins_mode(1);
    else rb_raise(rb_eArgError, "ins_mode must be :bulk or :aset");
    return mode;
}

static VALUE native_cache_mode(VALUE self) {
    (void)self;
    return yep_rb_cache_mode() == 1 ? ID2SYM(rb_intern("off")) : ID2SYM(rb_intern("on"));
}

static VALUE native_cache_mode_set(VALUE self, VALUE mode) {
    (void)self;
    Check_Type(mode, T_SYMBOL);
    ID id = rb_sym2id(mode);
    if (id == rb_intern("on")) yep_rb_set_cache_mode(0);
    else if (id == rb_intern("off")) yep_rb_set_cache_mode(1);
    else rb_raise(rb_eArgError, "cache_mode must be :on or :off");
    return mode;
}

static VALUE native_scan_time(VALUE self, VALUE input, VALUE count) {
    (void)self;
    StringValue(input);
    int n = NUM2INT(count);
    double secs = yep_rb_scan_time(RSTRING_PTR(input), (size_t)RSTRING_LEN(input), n);
    return DBL2NUM(secs / (double)n);
}

static VALUE native_shape_mode(VALUE self) {
    (void)self;
    return yep_rb_shape_mode() == 1 ? ID2SYM(rb_intern("natural")) : ID2SYM(rb_intern("pre"));
}

static VALUE native_shape_mode_set(VALUE self, VALUE mode) {
    (void)self;
    Check_Type(mode, T_SYMBOL);
    ID id = rb_sym2id(mode);
    if (id == rb_intern("pre")) yep_rb_set_shape_mode(0);
    else if (id == rb_intern("natural")) yep_rb_set_shape_mode(1);
    else rb_raise(rb_eArgError, "shape_mode must be :pre or :natural");
    return mode;
}

static VALUE native_gc_mode_set(VALUE self, VALUE mode) {
    (void)self;
    Check_Type(mode, T_SYMBOL);
    ID id = rb_sym2id(mode);
    if (id == rb_intern("disable")) yep_rb_set_gc_mode(0);
    else if (id == rb_intern("none")) yep_rb_set_gc_mode(1);
    else if (id == rb_intern("start")) yep_rb_set_gc_mode(2);
    else rb_raise(rb_eArgError, "gc_mode must be :disable, :none, or :start");
    return mode;
}

RUBY_FUNC_EXPORTED void Init_native(void) {
    utf8_enc = rb_utf8_encoding();
    VALUE mYep = rb_define_module("Yeptris");
    VALUE mNat = rb_define_module_under(mYep, "Native");
    rb_define_singleton_method(mNat, "load_json", native_load_json, -1);
    rb_define_singleton_method(mNat, "load", native_load, 2);
    rb_define_singleton_method(mNat, "load_stream", native_load_stream, 2);
    rb_define_singleton_method(mNat, "gc_mode", native_gc_mode, 0);
    rb_define_singleton_method(mNat, "gc_mode=", native_gc_mode_set, 1);
    rb_define_singleton_method(mNat, "ins_mode", native_ins_mode, 0);
    rb_define_singleton_method(mNat, "ins_mode=", native_ins_mode_set, 1);
    rb_define_singleton_method(mNat, "cache_mode", native_cache_mode, 0);
    rb_define_singleton_method(mNat, "cache_mode=", native_cache_mode_set, 1);
    rb_define_singleton_method(mNat, "shape_mode", native_shape_mode, 0);
    rb_define_singleton_method(mNat, "shape_mode=", native_shape_mode_set, 1);
    rb_define_singleton_method(mNat, "scan_time", native_scan_time, 2);
    rb_define_const(mNat, "AVAILABLE", Qtrue);
    const char* env = getenv("YEPTRIS_NATIVE_GC");
    if (env != NULL && strcmp(env, "none") == 0) yep_rb_set_gc_mode(1);
    else if (env != NULL && strcmp(env, "start") == 0) yep_rb_set_gc_mode(2);
    else if (env != NULL && strcmp(env, "disable") == 0) yep_rb_set_gc_mode(0);
    const char* ins = getenv("YEPTRIS_NATIVE_INSERT");
    if (ins != NULL && strcmp(ins, "aset") == 0) yep_rb_set_ins_mode(1);
    const char* cache = getenv("YEPTRIS_NATIVE_CACHE");
    if (cache != NULL && strcmp(cache, "off") == 0) yep_rb_set_cache_mode(1);
    const char* shape = getenv("YEPTRIS_NATIVE_SHAPE");
    if (shape != NULL && strcmp(shape, "natural") == 0) yep_rb_set_shape_mode(1);
}
