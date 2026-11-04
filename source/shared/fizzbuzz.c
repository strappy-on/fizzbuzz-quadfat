/*
 * fizzbuzz.c — FizzBuzz core implementation. Pure C99, stdio only.
 */
#include "fizzbuzz.h"

#include <stdio.h>
#include <stdint.h>

/*
 * Buffer for the numeric label returned by fizzbuzz_label().
 * INT32_MAX ("-2147483648") needs at most 11 characters plus NUL,
 * so 16 bytes is always sufficient for any int.
 */
static char label_buffer[16];

const char *fizzbuzz_label(int n)
{
    if (n % 3 == 0 && n % 5 == 0) {
        return "FizzBuzz";
    }
    if (n % 3 == 0) {
        return "Fizz";
    }
    if (n % 5 == 0) {
        return "Buzz";
    }
    snprintf(label_buffer, sizeof(label_buffer), "%d", n);
    return label_buffer;
}

void fizzbuzz_print_range(int from, int to)
{
    int n;
    for (n = from; n <= to; n++) {
        printf("%s\n", fizzbuzz_label(n));
    }
}
