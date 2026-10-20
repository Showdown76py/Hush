// app side shm open (shm_open is variadic so Swift can't call it)
#ifndef HUSH_APP_H
#define HUSH_APP_H

#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "hush_shm.h"

// opens (creates if needed) the shm. on failure returns NULL and sets *outErrno
static inline void *hush_app_map(int *outErrno) {
    int fd = shm_open(HUSH_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) { *outErrno = errno; return NULL; }
    fchmod(fd, 0666);
    struct stat st;
    if (fstat(fd, &st) != 0) { *outErrno = errno; close(fd); return NULL; }
    if (st.st_size == 0 && ftruncate(fd, (off_t)hush_shm_bytes()) != 0) { *outErrno = errno; close(fd); return NULL; }
    if (st.st_size != 0 && (size_t)st.st_size < hush_shm_bytes()) { *outErrno = EINVAL; close(fd); return NULL; }
    void *p = mmap(NULL, hush_shm_bytes(), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { *outErrno = errno; return NULL; }
    hush_app_attach(p, hush_shm_bytes());
    *outErrno = 0;
    return p;
}

static inline void hush_app_unmap(void *p) {
    if (p) munmap(p, hush_shm_bytes());
}

#endif
