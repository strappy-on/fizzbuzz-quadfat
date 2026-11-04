/*
 * main.c — fizzbuzz CLI entry point.
 *
 * Takes no arguments and prints FizzBuzz for 0..1000 inclusive, one
 * label per line, to stdout. 0 prints as "FizzBuzz".
 */
#include "../shared/fizzbuzz.h"

int main(void)
{
    fizzbuzz_print_range(0, 1000);
    return 0;
}
