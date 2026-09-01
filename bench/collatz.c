#include <stdio.h>

typedef struct { long total; long best; } Acc;

static long advance(const Acc *self, long n) {
    (void)self;
    return (n % 2 == 0) ? n / 2 : 3 * n + 1;
}

static long chain(const Acc *w, long start) {
    long n = start, count = 0;
    while (n != 1) { n = advance(w, n); count++; }
    return count;
}

int main(void) {
    Acc acc = {0, 0};
    long best = 0, total = 0;
    for (long i = 1; i < 300000; i++) {
        long c = chain(&acc, i);
        total += c;
        if (c > best) best = c;
    }
    printf("%ld\n%ld\n", total, best);
    return 0;
}
