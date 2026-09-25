/*
 * nif_mmap.c: pool_fits, kept apart from nif.h: the _POSIX_C_SOURCE it
 * defines hides MAP_ANON on macOS and FreeBSD, and this file needs nothing
 * else from it.
 */
#include <stddef.h>
#include <stdint.h>
#include <sys/mman.h>

int pool_fits(unsigned instances);

/* Whether the address space a pool reserves when its engine is created can
 * be reserved at all: under `ulimit -v` or strict overcommit it may not,
 * and Wasmtime aborts the process then. Each slot is the 4 GB memory
 * reservation, its 32 MB guard and about 1 MB of instance state; the probe
 * maps that much without access and unmaps it. */
int pool_fits(unsigned instances) {
  uint64_t per_slot = (4ull << 30) + (32ull << 20) + (1ull << 20);
  uint64_t bytes = per_slot * instances + (4ull << 30);
  if (bytes > SIZE_MAX) return 0;
  int flags = MAP_PRIVATE | MAP_ANON;
#ifdef MAP_NORESERVE
  flags |= MAP_NORESERVE;
#endif
  void *p = mmap(NULL, (size_t)bytes, PROT_NONE, flags, -1, 0);
  if (p == MAP_FAILED) return 0;
  munmap(p, (size_t)bytes);
  return 1;
}
