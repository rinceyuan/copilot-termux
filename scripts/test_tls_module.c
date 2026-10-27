/* A deliberately native-TLS fixture, loaded under each Copilot addon name. */
static __thread int value = 40;
static __thread unsigned char zero[256] __attribute__((aligned(64)));

__attribute__((constructor))
static void initialize(void) {
    value++;
    zero[0] = 7;
}
int tls_value(void) { return value; }
int tls_increment(void) { return ++value; }
void *tls_address(void) { return zero; }
int tls_zero(void) {
    int total = 0;
    for (unsigned i = 0; i < sizeof(zero); ++i) total += zero[i];
    return total;
}
double tls_arithmetic(double a, double b, double c, double d,
                      double e, double f, double g, double h) {
    return value + a + 2*b + 3*c + 4*d + 5*e + 6*f + 7*g + 8*h;
}
