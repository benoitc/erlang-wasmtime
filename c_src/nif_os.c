/*
 * nif_os.c: OS calls kept apart from nif.h: the _POSIX_C_SOURCE it defines
 * hides MAP_ANON and mkdtemp on macOS and FreeBSD, and this file needs
 * nothing else from it.
 */
/* glibc under -std=c11 declares mkdtemp, O_CLOEXEC and MAP_ANON only with
 * this; macOS and FreeBSD declare them by default. */
#define _DEFAULT_SOURCE

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int pool_fits(unsigned instances);
int private_fifo(char *path, size_t len, int *writer);
void private_fifo_remove(char *path);

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

/* A named pipe in a fresh private directory, for platforms where a pipe
 * cannot be reopened through /dev/fd (stdin_pipe_open). Opens its write end
 * O_RDWR, so neither this open nor the reader's waits for the other, and
 * writes the path to `path`. The caller opens the read end, then calls
 * private_fifo_remove. 0 on failure. */
int private_fifo(char *path, size_t len, int *writer) {
  char dir[] = "/tmp/wasmtime-stdin-XXXXXX";
  if (!mkdtemp(dir)) return 0;
  snprintf(path, len, "%s/stdin", dir);
  int w = -1;
  if (mkfifo(path, 0600) != 0 || (w = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC)) < 0) {
    unlink(path);
    rmdir(dir);
    return 0;
  }
  *writer = w;
  return 1;
}

/* Removes the pipe's name and its directory; open ends stay usable. */
void private_fifo_remove(char *path) {
  unlink(path);
  char *slash = strrchr(path, '/');
  if (slash) {
    *slash = 0;
    rmdir(path);
  }
}
