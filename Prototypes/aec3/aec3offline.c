// Rejoue AEC3 hors ligne sur une prise enregistrée par aec3cap (raw.wav + ref.wav alignés).
// Usage : aec3offline <raw.wav> <ref.wav> <ns 0..4> <out.wav>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "aec3_wrap.h"

static float *read_wav(const char *path, size_t *n) {   // format écrit par aec3cap : en-tête de 44 octets, float32
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 44, SEEK_SET);
    *n = (size_t)(size - 44) / 4;
    float *x = malloc(*n * 4);
    if (fread(x, 4, *n, f) != *n) { fprintf(stderr, "lecture %s\n", path); exit(1); }
    fclose(f);
    return x;
}

int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "usage : %s raw.wav ref.wav ns out.wav\n", argv[0]); return 2; }
    size_t nr, nf;
    float *raw = read_wav(argv[1], &nr), *ref = read_wav(argv[2], &nf);
    size_t n = (nr < nf ? nr : nf) / 480 * 480;
    float *out = calloc(n, 4);
    aec3_t *a = aec3_create(atoi(argv[3]));
    for (size_t i = 0; i < n; i += 480) aec3_process(a, ref + i, raw + i, out + i);
    // Même en-tête que l'entrée.
    FILE *in = fopen(argv[1], "rb"), *o = fopen(argv[4], "wb");
    unsigned char hdr[44];
    if (fread(hdr, 1, 44, in) != 44) return 1;
    unsigned int data = (unsigned int)(n * 4), riff = 36 + data;
    memcpy(hdr + 4, &riff, 4);
    memcpy(hdr + 40, &data, 4);
    fwrite(hdr, 1, 44, o);
    fwrite(out, 4, n, o);
    fclose(o); fclose(in);
    aec3_destroy(a);
    return 0;
}
