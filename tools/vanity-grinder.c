// CREATE3 vanity salt grinder for Ghost Escrow (see plans/ghost-escrow-vanity-deploy-plan.md).
//
// Address derivation (must mirror src/Create3Factory.sol exactly):
//   ns    = keccak256(opsEOA(20) || salt(32))
//   proxy = keccak256(0xff || factory(20) || ns || PROXY_INITCODE_HASH)[12..]
//   addr  = keccak256(0xd6 0x94 || proxy || 0x01)[12..]
// Target: addr starts with 3 zero BYTES (6 hex zeros) and ends with one of the
// wanted 2-byte suffixes. One pass finds every pattern; exits when all are hit.
//
// Build:  cc -O3 -march=native -pthread -o vanity-grinder vanity-grinder.c
// Run:    ./vanity-grinder <opsEOA hex> <factory hex> [threads]
// Output: appends "label salt address" lines to vanity-hits.txt (cwd), prints
//         progress to stdout. Salts embed thread-id + counter — resumable by
//         accident of randomness only; a re-run finds different salts, which is
//         fine (any hit is permanent once recorded).

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

#define ROTL64(x, y) (((x) << (y)) | ((x) >> (64 - (y))))

static const uint64_t RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL, 0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL, 0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL, 0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL, 0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL, 0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL, 0x0000000080000001ULL, 0x8000000080008008ULL};
static const int RHO[24] = {1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
                            27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44};
static const int PI[24] = {10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
                           15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1};

static void keccakf(uint64_t st[25]) {
    uint64_t bc[5], t;
    for (int r = 0; r < 24; r++) {
        for (int i = 0; i < 5; i++)
            bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20];
        for (int i = 0; i < 5; i++) {
            t = bc[(i + 4) % 5] ^ ROTL64(bc[(i + 1) % 5], 1);
            for (int j = 0; j < 25; j += 5) st[j + i] ^= t;
        }
        t = st[1];
        for (int i = 0; i < 24; i++) {
            int j = PI[i];
            bc[0] = st[j];
            st[j] = ROTL64(t, RHO[i]);
            t = bc[0];
        }
        for (int j = 0; j < 25; j += 5) {
            for (int i = 0; i < 5; i++) bc[i] = st[j + i];
            for (int i = 0; i < 5; i++) st[j + i] = bc[i] ^ ((~bc[(i + 1) % 5]) & bc[(i + 2) % 5]);
        }
        st[0] ^= RC[r];
    }
}

// keccak256 of a message < 136 bytes (rate): single-block absorb.
static void keccak256(const uint8_t *msg, size_t len, uint8_t out[32]) {
    uint64_t st[25] = {0};
    uint8_t block[136] = {0};
    memcpy(block, msg, len);
    block[len] = 0x01;      // Keccak (pre-SHA3) domain padding — Ethereum's
    block[135] |= 0x80;
    for (int i = 0; i < 17; i++) {
        uint64_t w = 0;
        for (int b = 0; b < 8; b++) w |= (uint64_t)block[i * 8 + b] << (8 * b);
        st[i] ^= w;
    }
    keccakf(st);
    for (int i = 0; i < 4; i++)
        for (int b = 0; b < 8; b++) out[i * 8 + b] = (uint8_t)(st[i] >> (8 * b));
}

typedef struct { uint8_t b[2]; const char *label; int wanted; } target_t;
static target_t targets[] = {
    {{0xfa, 0xc7}, "factory:fac7", 1},
    {{0xde, 0xa1}, "template:dea1", 2},
    {{0x5a, 0xfe}, "registry:5afe", 1},
    {{0x5e, 0xa1}, "court:5ea1", 1},
};
#define NTARGETS 4

static uint8_t OPS[20], FACTORY[20], PROXY_HASH[32];
static atomic_ulong found[NTARGETS];
static atomic_ulong total_hashes;
static atomic_int done_flag;
static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

static int hex2bin(const char *hex, uint8_t *out, size_t n) {
    if (!strncmp(hex, "0x", 2)) hex += 2;
    if (strlen(hex) != n * 2) return -1;
    for (size_t i = 0; i < n; i++) {
        unsigned v;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1;
        out[i] = (uint8_t)v;
    }
    return 0;
}

static void *grind(void *arg) {
    uint64_t tid = (uint64_t)(uintptr_t)arg;
    uint8_t buf1[52], buf2[85], buf3[23], ns[32], h[32];
    memcpy(buf1, OPS, 20);
    memset(buf1 + 20, 0, 32);
    buf1[20] = (uint8_t)tid;                       // thread lane
    buf1[21] = (uint8_t)(time(NULL) & 0xff);       // run nonce: re-runs explore new space
    buf2[0] = 0xff; memcpy(buf2 + 1, FACTORY, 20); memcpy(buf2 + 53, PROXY_HASH, 32);
    buf3[0] = 0xd6; buf3[1] = 0x94; buf3[22] = 0x01;

    for (uint64_t ctr = 0;; ctr++) {
        if (atomic_load(&done_flag)) return NULL;
        for (int b = 0; b < 8; b++) buf1[44 + b] = (uint8_t)(ctr >> (8 * b));
        keccak256(buf1, 52, ns);
        memcpy(buf2 + 21, ns, 32);
        keccak256(buf2, 85, h);
        memcpy(buf3 + 2, h + 12, 20);
        keccak256(buf3, 23, h);
        // addr = h[12..31]; need h[12]==h[13]==h[14]==0
        if ((h[12] | h[13] | h[14]) == 0) {
            for (int t = 0; t < NTARGETS; t++) {
                if (h[30] == targets[t].b[0] && h[31] == targets[t].b[1]) {
                    if (atomic_fetch_add(&found[t], 1) < (unsigned long)targets[t].wanted) {
                        pthread_mutex_lock(&out_lock);
                        FILE *f = fopen("vanity-hits.txt", "a");
                        fprintf(f, "%s salt=0x", targets[t].label);
                        for (int i = 0; i < 32; i++) fprintf(f, "%02x", buf1[20 + i]);
                        fprintf(f, " addr=0x");
                        for (int i = 12; i < 32; i++) fprintf(f, "%02x", h[i]);
                        fprintf(f, "\n");
                        fclose(f);
                        printf("HIT %s addr=0x", targets[t].label);
                        for (int i = 12; i < 32; i++) printf("%02x", h[i]);
                        printf("\n");
                        fflush(stdout);
                        pthread_mutex_unlock(&out_lock);
                        int all = 1;
                        for (int k = 0; k < NTARGETS; k++)
                            if (atomic_load(&found[k]) < (unsigned long)targets[k].wanted) all = 0;
                        if (all) { atomic_store(&done_flag, 1); return NULL; }
                    }
                }
            }
        }
        if ((ctr & 0xfffff) == 0) atomic_fetch_add(&total_hashes, 0x100000);
    }
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <opsEOA> <create3Factory> [threads]\n", argv[0]); return 1; }
    if (hex2bin(argv[1], OPS, 20) || hex2bin(argv[2], FACTORY, 20)) { fprintf(stderr, "bad address\n"); return 1; }
    const uint8_t proxy_init[16] = {0x67, 0x36, 0x3d, 0x3d, 0x37, 0x36, 0x3d, 0x34,
                                    0xf0, 0x3d, 0x52, 0x60, 0x08, 0x60, 0x18, 0xf3};
    keccak256(proxy_init, 16, PROXY_HASH);
    printf("proxy initcode hash: 0x");
    for (int i = 0; i < 32; i++) printf("%02x", PROXY_HASH[i]);
    printf("\n");

    // Self-test mode: a 4th arg = exact 32-byte salt; print its address, exit.
    if (argc > 4 && !strcmp(argv[3], "test")) {
        uint8_t salt[32], buf1[52], buf2[85], buf3[23], h[32];
        if (hex2bin(argv[4], salt, 32)) { fprintf(stderr, "bad salt\n"); return 1; }
        memcpy(buf1, OPS, 20); memcpy(buf1 + 20, salt, 32);
        keccak256(buf1, 52, h);
        buf2[0] = 0xff; memcpy(buf2 + 1, FACTORY, 20); memcpy(buf2 + 21, h, 32); memcpy(buf2 + 53, PROXY_HASH, 32);
        keccak256(buf2, 85, h);
        buf3[0] = 0xd6; buf3[1] = 0x94; memcpy(buf3 + 2, h + 12, 20); buf3[22] = 0x01;
        keccak256(buf3, 23, h);
        printf("addr=0x"); for (int i = 12; i < 32; i++) printf("%02x", h[i]); printf("\n");
        return 0;
    }

    int nthreads = argc > 3 ? atoi(argv[3]) : 8;
    pthread_t th[64];
    for (int i = 0; i < nthreads; i++) pthread_create(&th[i], NULL, grind, (void *)(uintptr_t)i);

    time_t t0 = time(NULL);
    while (!atomic_load(&done_flag)) {
        sleep(30);
        unsigned long h = atomic_load(&total_hashes);
        double el = (double)(time(NULL) - t0);
        printf("[progress] %.1f Mcand tried, %.2f Mcand/s, elapsed %.0f min\n",
               h / 1e6, h / el / 1e6, el / 60);
        fflush(stdout);
    }
    for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
    printf("ALL TARGETS FOUND — see vanity-hits.txt\n");
    return 0;
}
