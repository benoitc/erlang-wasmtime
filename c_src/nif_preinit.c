/*
 * nif_preinit.c: What wasmtime_preinit.erl reads from an initialized
 * instance to build a pre-initialized module: the non-zero ranges of a
 * memory, the raw bits of a global, a fingerprint of a funcref table.
 * The scan follows Wizer's snapshot (Wasmtime's crates/wizer): ranges are
 * found per page, merged across gaps of at most 4 bytes, and capped at
 * 10000 segments by merging the smallest gaps.
 */
#include "nif.h"

#define MAX_SEGMENTS 10000
#define MERGE_GAP 4 /* an active segment costs about this much to encode */

typedef struct {
  size_t start, end;
} range_t;

typedef struct {
  range_t *v;
  size_t n, cap;
} ranges_t;

static void push(ranges_t *r, size_t start, size_t end) {
  if (r->n == r->cap) {
    r->cap = r->cap ? r->cap * 2 : 256;
    r->v = enif_realloc(r->v, r->cap * sizeof *r->v);
  }
  r->v[r->n].start = start;
  r->v[r->n].end = end;
  r->n++;
}

/* Non-zero runs within each page, a run never crossing a page boundary,
 * merged with the previous run when the gap is small. */
static void scan(const uint8_t *mem, size_t size, size_t page, ranges_t *r) {
  for (size_t p = 0; p < size; p += page) {
    size_t end = p + page < size ? p + page : size, i = p;
    while (i < end) {
      while (i < end && mem[i] == 0) i++;
      if (i == end) break;
      size_t s = i;
      while (i < end && mem[i] != 0) i++;
      if (r->n && s - r->v[r->n - 1].end <= MERGE_GAP)
        r->v[r->n - 1].end = i;
      else
        push(r, s, i);
    }
  }
}

static int cmp_size(const void *a, const void *b) {
  size_t x = *(const size_t *)a, y = *(const size_t *)b;
  return x < y ? -1 : x > y;
}

/* Merges the smallest gaps until MAX_SEGMENTS remain. */
static void cap_segments(ranges_t *r) {
  if (r->n <= MAX_SEGMENTS) return;
  size_t excess = r->n - MAX_SEGMENTS;
  size_t *gaps = enif_alloc((r->n - 1) * sizeof *gaps);
  for (size_t i = 0; i + 1 < r->n; i++) gaps[i] = r->v[i + 1].start - r->v[i].end;
  qsort(gaps, r->n - 1, sizeof *gaps, cmp_size);
  size_t threshold = gaps[excess - 1], below = 0;
  for (size_t i = 0; i < excess; i++) below += gaps[i] < threshold;
  size_t at_threshold = excess - below; /* how many gaps equal to it merge */
  enif_free(gaps);
  size_t out = 0;
  for (size_t i = 1; i < r->n; i++) {
    size_t gap = r->v[i].start - r->v[out].end;
    int merge = gap < threshold || (gap == threshold && at_threshold > 0);
    if (merge) {
      if (gap == threshold) at_threshold--;
      r->v[out].end = r->v[i].end;
    } else {
      r->v[++out] = r->v[i];
    }
  }
  r->n = out + 1;
}

/* preinit_memory(Handle, Name) -> {ok, Pages, [{Offset, Bytes}]}
 * Dirty CPU: a 40 MB memory is scanned in about 10 ms. */
ERL_NIF_TERM nif_preinit_memory(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  const uint8_t *data = wasmtime_memory_data(inst->wasm.ctx, &mem);
  size_t size = wasmtime_memory_data_size(inst->wasm.ctx, &mem);
  size_t page = (size_t)1 << wasmtime_memory_page_size_log2(inst->wasm.ctx, &mem);
  ranges_t r = {0};
  scan(data, size, page, &r);
  cap_segments(&r);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = r.n; i > 0; i--) {
    range_t *g = &r.v[i - 1];
    list = enif_make_list_cell(env,
                               enif_make_tuple2(env, enif_make_uint64(env, g->start),
                                                mk_binary(env, data + g->start, g->end - g->start)),
                               list);
  }
  enif_free(r.v);
  pthread_mutex_unlock(&inst->mu);
  return enif_make_tuple3(env, atom_ok, enif_make_uint64(env, size / page), list);
}

/* preinit_global(Handle, Name) -> {ok, i32 | i64 | f32 | f64 | v128, Bits}
 * The bits little-endian, so a NaN keeps its payload. */
ERL_NIF_TERM nif_preinit_global(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_GLOBAL, "global", &inst, &ext);
  if (err) return err;
  wasmtime_val_t v;
  wasmtime_global_get(inst->wasm.ctx, &ext.of.global, &v);
  pthread_mutex_unlock(&inst->mu);
  uint8_t bits[16];
  const char *kind;
  size_t n;
  switch (v.kind) {
  case WASMTIME_I32: kind = "i32", n = 4, memcpy(bits, &v.of.i32, 4); break;
  case WASMTIME_I64: kind = "i64", n = 8, memcpy(bits, &v.of.i64, 8); break;
  case WASMTIME_F32: kind = "f32", n = 4, memcpy(bits, &v.of.f32, 4); break;
  case WASMTIME_F64: kind = "f64", n = 8, memcpy(bits, &v.of.f64, 8); break;
  case WASMTIME_V128: kind = "v128", n = 16, memcpy(bits, v.of.v128, 16); break;
  default:
    wasmtime_val_unroot(&v);
    return mk_error_s(env, "preinit", "unsupported_type", "a reference global cannot be captured");
  }
  /* The C API is little-endian only, like every host Wasmtime supports. */
  return enif_make_tuple3(env, atom_ok, mk_atom(env, kind), mk_binary(env, bits, n));
}

/* preinit_table(Handle, Name) -> {ok, Fingerprint}
 * The size and every element's identity, to compare before and after the
 * init calls: a snapshot does not carry tables, so a table the init calls
 * changed makes the result wrong. A funcref's identity is stable within
 * one instance. */
ERL_NIF_TERM nif_preinit_table(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  (void)argc;
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  uint64_t size = wasmtime_table_size(inst->wasm.ctx, &ext.of.table);
  ErlNifBinary out;
  enif_alloc_binary(8 + size * (8 + sizeof(void *)), &out);
  memcpy(out.data, &size, 8);
  uint8_t *p = out.data + 8;
  const char *refused = NULL;
  for (uint64_t i = 0; i < size && !refused; i++) {
    wasmtime_val_t v;
    if (!wasmtime_table_get(inst->wasm.ctx, &ext.of.table, i, &v)) {
      refused = "table element out of range";
    } else if (v.kind != WASMTIME_FUNCREF) {
      wasmtime_val_unroot(&v);
      refused = "only funcref tables can be checked";
    } else {
      memcpy(p, &v.of.funcref.store_id, 8);
      memcpy(p + 8, &v.of.funcref.__private, sizeof(void *));
      p += 8 + sizeof(void *);
    }
  }
  pthread_mutex_unlock(&inst->mu);
  if (refused) {
    enif_release_binary(&out);
    return mk_error_s(env, "preinit", "unsupported_type", refused);
  }
  return enif_make_tuple2(env, atom_ok, enif_make_binary(env, &out));
}
