#include <stdio.h>
#include <stdlib.h>

int main(void) {
    long limit = 2000000;
    long *flags = malloc((size_t)(limit + 1) * sizeof(long));
    for (long i = 0; i <= limit; i++) flags[i] = 1;

    for (long p = 2; p * p <= limit; p++)
        if (flags[p] == 1)
            for (long m = p * p; m <= limit; m += p) flags[m] = 0;

    long count = 0;
    for (long n = 2; n <= limit; n++) count += flags[n];

    printf("%ld\n", count);
    free(flags);
    return 0;
}
