/* json_ruby.c — fused RFC 8259 → Ruby VALUE (TODO.restructure/22). */
#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/intern.h>
#include <stdlib.h>
#include <string.h>
#include "parse/scalars.h"
#include <yeptris/visit.h>
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
    int strict_dup; /* json gem >= 3: duplicate keys raise (issue #37) */
    VALUE dup_key;
    kcent kc[YEP_KC];
} jr;

static VALUE jr_value(jr* j);
static VALUE jr_object_body(jr* j, VALUE h_pre);

static void jr_ws(jr* j) {
    while (j->i < j->len) {
        unsigned char c = (unsigned char)j->p[j->i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') j->i++;
        else break;
    }
}

/* Token-cache knob (TODO.restructure/37): off = fresh strings
 * everywhere (JSON.parse's shape: every key pays its own aset
 * hashing); on = interned keys/tokens (shared frozen VALUEs
 * memoize their hash). The CI referee A/Bs the net sign per arch. */
enum { YEP_CACHE_ON = 0, YEP_CACHE_OFF = 1 };
static int yep_cache_mode = YEP_CACHE_ON;

/* Allocation-shape knob (TODO.restructure/39): pre = capa(8) up
 * front (forces heap buffers even for tiny arrays); natural =
 * rb_ary_new() so 3-element arrays stay EMBEDDED in the RVALUE, and
 * bulk-path hashes get exact capacity from the counted pairs. */
enum { YEP_SHAPE_PRE = 0, YEP_SHAPE_NATURAL = 1 };
static int yep_shape_mode = YEP_SHAPE_PRE;

static uint64_t jr_hash(const char* sp, long sl) {
    /* 8-byte-prefix key (the leptris nametab trick): one safe load
     * of min(8, len) bytes + a multiply mix. Replaced byte-wise FNV
     * (~15-20ns per token on the cached path, ~15k tokens per
     * reference-corpus parse - the x86 materialization cost the
     * decomposition isolated, TODO.restructure/37/38). */
    uint64_t k = 0;
    uint64_t take = (uint64_t)sl < 8 ? (uint64_t)sl : 8;
    memcpy(&k, sp, (size_t)take);
    k ^= (uint64_t)sl * 0x9E3779B97F4A7C15ull;
    k *= 0xC2B2AE3D27D4EB4Full;
    k ^= k >> 29;
    return k;
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
    if (yep_cache_mode == YEP_CACHE_ON && (as_key || sl <= 24)) return jr_cached(j, sp, sl);
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

/* Insert strategy (TODO.restructure/34): bulk lands all pairs in one
 * rb_hash_bulk_insert (skips per-pair dispatch) but costs +1.4k
 * intermediate allocations on the reference corpus — the CI referee
 * rules per platform. aset = the per-pair rb_hash_aset loop. */
enum { YEP_INS_BULK = 0, YEP_INS_ASET = 1 };
static int yep_ins_mode = YEP_INS_BULK;

static VALUE jr_object(jr* j) {
    j->i++; j->depth++;
    if (yep_shape_mode == YEP_SHAPE_PRE) {
        VALUE h = rb_hash_new_capa(8);
        jr_ws(j);
        if (j->i < j->len && j->p[j->i] == '}') { j->i++; j->depth--; return h; }
        return jr_object_body(j, h);
    }
    jr_ws(j);
    if (j->i < j->len && j->p[j->i] == '}') { j->i++; j->depth--; return rb_hash_new(); }
    return jr_object_body(j, Qundef); /* created post-loop with exact capa */

    /* NOTREACHED */
}

static VALUE jr_object_body(jr* j, VALUE h_pre) {
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
        if (yep_ins_mode == YEP_INS_ASET || j->strict_dup) {
            VALUE h = h_pre == Qundef ? (h_pre = rb_hash_new_capa(8)) : h_pre;
            if (j->strict_dup && !NIL_P(rb_hash_aref(h, key))) {
                j->err = -3;
                j->dup_key = key;
                goto out;
            }
            rb_hash_aset(h, key, val);
        } else {
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
        }
        jr_ws(j);
        if (j->i >= j->len) { j->err = -2; goto out; }
        if (j->p[j->i] == ',') { j->i++; continue; }
        if (j->p[j->i] == '}') { j->i++; break; }
        j->err = -2; goto out;
    }
    if (yep_ins_mode == YEP_INS_BULK) {
        VALUE h = (h_pre == Qundef) ? rb_hash_new_capa((long)(pn / 2)) : h_pre;
        rb_hash_bulk_insert((long)pn, (const VALUE*)pv, h);
        if (pv != pairs) { free(pv); }
        j->depth--;
        return h;
    }
    if (h_pre == Qundef) { h_pre = rb_hash_new_capa(8); }
out:
    if (pv != pairs) { free(pv); (void)heap_cap; }
    if (j->err) return Qnil;
    j->depth--;
    return h_pre;
}

static VALUE jr_array(jr* j) {
    j->i++; j->depth++;
    VALUE a = (yep_shape_mode == YEP_SHAPE_NATURAL) ? rb_ary_new() : rb_ary_new_capa(8);
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

/* GC strategy for the parse window (TODO.restructure/34): JSON.parse
 * pays minor GCs mid-parse and recycles slots continuously; a blanket
 * disable defers every collection — fresh pages each iteration, which
 * is cheap idle and expensive exactly under memory contention (the
 * loaded-box regression). The strategy is a runtime choice so the CI
 * referee can A/B without rebuilds:
 *   disable (default) — pause GC for the window
 *   none               — never pause
 *   start              — pause, then one gc_start before returning
 *                        (pay the minor GC in-window, like JSON.parse)
 */
enum { YEP_GC_DISABLE = 0, YEP_GC_NONE = 1, YEP_GC_START = 2 };
/* Default per arch (TODO.restructure/35, two CI rounds of evidence):
 * - aarch64/darwin: NONE — +0 heap pages, the stdlib's own GC cadence
 *   (0.745x mean, h2h 91% on mac runners; disable was 0.899x/48%).
 * - x86_64: DISABLE — fresh CI VMs have free pages and cheaper
 *   page faults than minor GCs (0.911-0.922x vs none's 1.06-1.20x).
 * The mechanism cuts both ways under load: disable's +478 pages/50
 * iters is exactly what a LOADED x86 box punishes — set
 * YEPTRIS_NATIVE_GC=none there (documented in README). */
#if defined(__aarch64__) || defined(__arm__) || defined(__ARMEL__) || defined(_M_ARM64)
#define YEP_GC_DEFAULT YEP_GC_NONE
#else
#define YEP_GC_DEFAULT YEP_GC_DISABLE
#endif
static int yep_gc_mode = YEP_GC_DEFAULT;

int yep_rb_gc_mode(void) { return yep_gc_mode; }
int yep_rb_ins_mode(void) { return yep_ins_mode; }
int yep_rb_cache_mode(void) { return yep_cache_mode; }
int yep_rb_shape_mode(void) { return yep_shape_mode; }
void yep_rb_set_shape_mode(int mode) {
    if (mode == YEP_SHAPE_PRE || mode == YEP_SHAPE_NATURAL) yep_shape_mode = mode;
}
void yep_rb_set_cache_mode(int mode) {
    if (mode == YEP_CACHE_ON || mode == YEP_CACHE_OFF) yep_cache_mode = mode;
}
void yep_rb_set_ins_mode(int mode) {
    if (mode == YEP_INS_BULK || mode == YEP_INS_ASET) yep_ins_mode = mode;
}
void yep_rb_set_gc_mode(int mode) {
    if (mode >= YEP_GC_DISABLE && mode <= YEP_GC_START) {
        yep_gc_mode = mode;
    }
}

/* Pure grammar walk, no materialization (TODO.restructure/37): the
 * same scan kernels through the null vtable. Decomposes scan vs
 * materialize cost. Returns seconds for n iterations. */
#include <time.h>
double yep_rb_scan_time(const char* p, size_t len, int n) {
    static const YeptrisVisitVTable none = {0};
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < n; i++) {
        (void)yeptris_visit_json(p, len, &none, NULL);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    return (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
}

VALUE yep_rb_parse_json(const char* p, size_t len, int strict_dup) {
    jr j;
    memset(&j, 0, sizeof(j));
    j.p = p; j.len = len; j.enc = rb_utf8_encoding();
    j.strict_dup = strict_dup;
    VALUE already = Qtrue;
    if (yep_gc_mode != YEP_GC_NONE) already = rb_gc_disable();
    VALUE v = jr_value(&j);
    jr_ws(&j);
    if (j.i != len && j.err == 0) j.err = -2;
    free(j.scratch);
    if (already == Qfalse) rb_gc_enable();
    if (yep_gc_mode == YEP_GC_START && j.err == 0) rb_gc_start();
    if (j.err == -1) rb_raise(rb_eNoMemError, "yeptris native json");
    if (j.err == -3) {
        rb_raise(rb_path2class("Yeptris::ParseError"), "duplicate key \"%s\" in JSON object",
                 RSTRING_PTR(j.dup_key));
    }
    if (j.err != 0) rb_raise(rb_path2class("Yeptris::ParseError"), "native json parse failed");
    return v;
}
