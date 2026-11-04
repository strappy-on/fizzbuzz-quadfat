/*
 * fizzbuzz.h — FizzBuzz core, pure C99, no platform-specific headers.
 */
#ifndef FIZZBUZZ_H
#define FIZZBUZZ_H

/*
 * Return the label for a single integer n:
 *   - "FizzBuzz" if n is divisible by 15,
 *   - "Fizz"     if n is divisible by 3,
 *   - "Buzz"     if n is divisible by 5,
 *   - the decimal representation of n otherwise.
 * n = 0 is divisible by 3 and 5, so fizzbuzz_label(0) == "FizzBuzz".
 * The returned pointer references a static buffer valid until the next
 * call to fizzbuzz_label; callers must not free it and must copy the
 * string if they need it to outlive further calls.
 */
const char *fizzbuzz_label(int n);

/*
 * Print one line per integer in the inclusive range [from, to] to
 * stdout, using the fizzbuzz_label() rules. Prints nothing if
 * from > to.
 */
void fizzbuzz_print_range(int from, int to);

#endif /* FIZZBUZZ_H */
