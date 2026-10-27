#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); exit(1); \
} } while (0)
struct api {
    int (*value)(void), (*increment)(void), (*zero)(void);
    void *(*address)(void);
    double (*arithmetic)(double, double, double, double, double, double, double, double);
};
static struct api modules[2];
static uintptr_t addresses[4][2];
static pthread_barrier_t barrier;

static void *worker(void *arg) {
    uintptr_t index = (uintptr_t)arg;
    for (int m = 0; m < 2; ++m) {
        struct api *api = &modules[m];
        CHECK(api->value() == 40 && api->zero() == 0);
        addresses[index][m] = (uintptr_t)api->address();
        CHECK(addresses[index][m] % 64 == 0);
        for (int n = 41; n <= 60; ++n) CHECK(api->increment() == n);
        CHECK(api->arithmetic(1, 2, 3, 4, 5, 6, 7, 8) == 264);
    }
    pthread_barrier_wait(&barrier);
    return NULL;
}

int main(int argc, char **argv) {
    CHECK(argc == 3);
    void *handles[2];
    for (int m = 0; m < 2; ++m) {
        handles[m] = dlopen(argv[m + 1], RTLD_NOW | RTLD_LOCAL);
        if (!handles[m]) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        modules[m].value = (int (*)(void))dlsym(handles[m], "tls_value");
        modules[m].increment = (int (*)(void))dlsym(handles[m], "tls_increment");
        modules[m].zero = (int (*)(void))dlsym(handles[m], "tls_zero");
        modules[m].address = (void *(*)(void))dlsym(handles[m], "tls_address");
        modules[m].arithmetic = (double (*)(double, double, double, double, double, double, double, double))
            dlsym(handles[m], "tls_arithmetic");
        CHECK(modules[m].value && modules[m].increment && modules[m].zero &&
              modules[m].address && modules[m].arithmetic);
        CHECK(modules[m].value() == 41 && modules[m].zero() == 7);
    }
    puts("PASS: native TLS works during both addon constructors");
    CHECK(pthread_barrier_init(&barrier, NULL, 4) == 0);
    pthread_t threads[4];
    for (uintptr_t i = 0; i < 4; ++i) CHECK(pthread_create(&threads[i], NULL, worker, (void *)i) == 0);
    for (int i = 0; i < 4; ++i) CHECK(pthread_join(threads[i], NULL) == 0);
    for (int i = 0; i < 4; ++i) {
        CHECK(addresses[i][0] != addresses[i][1]);
        for (int j = 0; j < i; ++j)
            for (int m = 0; m < 2; ++m) CHECK(addresses[i][m] != addresses[j][m]);
    }
    for (int m = 0; m < 2; ++m) CHECK(modules[m].value() == 41 && modules[m].zero() == 7);
    pthread_barrier_destroy(&barrier);
    puts("PASS: TLS initialization, alignment, thread/module isolation and SIMD preservation");
    /* Match Node's addon lifetime: keep modules mapped until process exit. */
    return 0;
}
