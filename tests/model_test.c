/*
 * model_test.c — standalone host test for the FizzBuzz core.
 *
 * Compiles on any POSIX host with plain `cc -std=c99 -Wall -Wextra`
 * and no dependencies beyond libc. Verifies:
 *   1. fizzbuzz_label() for a set of known values,
 *   2. fizzbuzz_print_range(0, 1000) emits exactly 1001 lines,
 *   3. the first line is "FizzBuzz" and the last line is "Buzz",
 *   4. a set of mid-range values at their exact line positions.
 *
 * Range output is captured by forking a child that writes the range
 * to a pipe; the parent drains the pipe into memory, verifies the
 * lines, and reports failures.
 *
 * Prints "ALL TESTS PASSED" and exits 0 on success; exits 1 on any
 * failure.
 */
#define _POSIX_C_SOURCE 200809L

#include "fizzbuzz.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>

#define RANGE_START 0
#define RANGE_END   1000
#define RANGE_LINES (RANGE_END - RANGE_START + 1)

/*
 * Initial buffer size for captured range output: every line is at most
 * 11 chars ("-2147483648") plus newline, so 1001 * 13 = 13013 bytes for
 * 0..1000. 64 KiB gives ample headroom and the buffer grows on demand
 * regardless.
 */
#define CAPTURE_BUF_SIZE 65536

static int failures = 0;

static void check_label(int n, const char *expected)
{
    const char *actual = fizzbuzz_label(n);
    if (strcmp(actual, expected) == 0) {
        printf("ok: fizzbuzz_label(%d) == \"%s\"\n", n, actual);
    } else {
        printf("FAIL: fizzbuzz_label(%d) = \"%s\", expected \"%s\"\n",
               n, actual, expected);
        failures++;
    }
}

/*
 * Run fizzbuzz_print_range(RANGE_START, RANGE_END) in a child process
 * whose stdout is a pipe; the parent reads the complete output into a
 * malloc'd buffer. Returns a NUL-terminated buffer (caller frees) or
 * NULL on failure (failures already incremented).
 *
 * The parent drains the pipe to EOF before waitpid() so the child can
 * never block on a full pipe buffer, making the wait guaranteed to
 * complete.
 */
static char *capture_range_output(size_t *out_len)
{
    int pfd[2];
    pid_t child;
    int status = 0;
    char *buf = NULL;
    size_t len = 0;
    size_t cap = 0;
    ssize_t r;

    if (out_len != NULL) {
        *out_len = 0;
    }

    if (pipe(pfd) != 0) {
        perror("pipe");
        failures++;
        return NULL;
    }

    child = fork();
    if (child < 0) {
        perror("fork");
        close(pfd[0]);
        close(pfd[1]);
        failures++;
        return NULL;
    }

    if (child == 0) {
        /*
         * Child: redirect the *fd* 1 (not just stdio's stdout FILE*)
         * to the write end of the pipe so printf's buffered output
         * actually lands in the pipe. The parent's test-log FILE
         * handles are irrelevant here; we restore fd 1 before exit so
         * stdio's final flush on _exit() does not write range data
         * anywhere unintended.
         */
        int saved_stdout = dup(STDOUT_FILENO);
        if (saved_stdout < 0) {
            _exit(1);
        }
        if (dup2(pfd[1], STDOUT_FILENO) < 0) {
            _exit(1);
        }
        close(pfd[0]);
        close(pfd[1]);
        fizzbuzz_print_range(RANGE_START, RANGE_END);
        fflush(stdout);
        if (dup2(saved_stdout, STDOUT_FILENO) < 0) {
            _exit(1);
        }
        close(saved_stdout);
        _exit(0);
    }

    /* Parent: close write end so EOF arrives once the child exits. */
    close(pfd[1]);

    for (;;) {
        if (len + 1 >= cap) {
            size_t new_cap = (cap == 0) ? CAPTURE_BUF_SIZE : cap * 2;
            char *nb = realloc(buf, new_cap);
            if (nb == NULL) {
                free(buf);
                buf = NULL;
                printf("FAIL: out of memory capturing range output\n");
                failures++;
                return NULL;
            }
            buf = nb;
            cap = new_cap;
        }
        r = read(pfd[0], buf + len, cap - len - 1);
        if (r < 0) {
            perror("read");
            free(buf);
            failures++;
            return NULL;
        }
        if (r == 0) {
            break; /* EOF */
        }
        len += (size_t)r;
    }
    close(pfd[0]);

    waitpid(child, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        printf("FAIL: child fizzbuzz_print_range exited abnormally\n");
        free(buf);
        failures++;
        return NULL;
    }

    if (buf != NULL) {
        buf[len] = '\0';
    }
    if (out_len != NULL) {
        *out_len = len;
    }
    return buf;
}

/*
 * Split a captured range output into lines. Returns an array of
 * NUL-terminated line pointers (length *out_count); the array is
 * malloc'd, caller frees it. Lines are NUL-terminated in place
 * (newlines become NULs), so `buf` must stay allocated until the
 * caller is done with the lines. Returns NULL on allocation failure.
 */
static char **split_lines(const char *buf, size_t len, size_t *out_count)
{
    size_t newlines = 0;
    size_t nlines;
    size_t i;
    char **lines;

    *out_count = 0;

    if (len == 0) {
        return NULL;
    }

    for (i = 0; i < len; i++) {
        if (buf[i] == '\n') {
            newlines++;
        }
    }

    /*
     * A buffer of N newlines holds N lines if it ends in '\n', and N+1
     * lines otherwise (a final line without a trailing newline). The
     * fill loop below stores exactly this many segments.
     */
    if (buf[len - 1] == '\n') {
        nlines = newlines;
    } else {
        nlines = newlines + 1;
    }

    lines = malloc(nlines * sizeof(char *));
    if (lines == NULL) {
        printf("FAIL: out of memory splitting lines\n");
        failures++;
        return NULL;
    }

    /*
     * Fill the array, NUL-terminating each line in place (newlines
     * become NULs). If the buffer ends in '\n' the final empty tail
     * segment is skipped so the stored count equals `nlines`.
     */
    {
        char *w = (char *)buf;
        const char *end = (char *)buf + len;
        char *line_start = w;
        size_t idx = 0;

        for (;;) {
            if (w == end || *w == '\n') {
                if (!(w == end && line_start == w)) {
                    /* Skip only the empty tail after a final newline. */
                    *w = '\0';
                    lines[idx++] = line_start;
                }
                if (w == end) {
                    break;
                }
                w++;
                line_start = w;
            } else {
                w++;
            }
        }
        *out_count = idx;
    }

    return lines;
}

static void check_line_array(char **lines, size_t count)
{
    const char *first = (count > 0) ? lines[0] : "(none)";
    const char *last = (count > 0) ? lines[count - 1] : "(none)";
    static const struct {
        int n;
        const char *expected;
    } mid[] = {
        { 30,  "FizzBuzz" },
        { 333, "Fizz"     },
        { 995, "Buzz"     },
        { 999, "Fizz"     },
    };
    size_t k;

    /* 2. Exactly 1001 lines. */
    if (count == (size_t)RANGE_LINES) {
        printf("ok: range(0,1000) emitted exactly %d lines\n",
               (int)count);
    } else {
        printf("FAIL: range(0,1000) emitted %zu lines, expected %d\n",
               count, RANGE_LINES);
        failures++;
    }

    /* 3. First line "FizzBuzz" (n=0), last line "Buzz" (n=1000). */
    if (count > 0 && strcmp(first, "FizzBuzz") == 0) {
        printf("ok: first line (n=0) == \"FizzBuzz\"\n");
    } else {
        printf("FAIL: first line (n=0) = \"%s\", expected \"FizzBuzz\"\n",
               first);
        failures++;
    }

    if (count > 0 && strcmp(last, "Buzz") == 0) {
        printf("ok: last line (n=1000) == \"Buzz\"\n");
    } else {
        printf("FAIL: last line (n=1000) = \"%s\", expected \"Buzz\"\n",
               last);
        failures++;
    }

    /* 4. Mid-range values at their exact positions (line index = n). */
    for (k = 0; k < sizeof(mid) / sizeof(mid[0]); k++) {
        int n = mid[k].n;
        if (n >= RANGE_START && (size_t)(n - RANGE_START) < count) {
            const char *actual = lines[n - RANGE_START];
            if (strcmp(actual, mid[k].expected) == 0) {
                printf("ok: line for n=%d == \"%s\"\n", n, mid[k].expected);
            } else {
                printf("FAIL: line for n=%d = \"%s\", expected \"%s\"\n",
                       n, actual, mid[k].expected);
                failures++;
            }
        } else {
            printf("FAIL: line for n=%d out of captured range\n", n);
            failures++;
        }
    }
}

int main(void)
{
    size_t len = 0;
    size_t line_count = 0;
    char *buf;
    char **lines;

    /*
     * Run the pipe-based capture BEFORE any test logging: the child
     * process inherits the parent's stdout fd, and the pipe is only
     * isolated from the parent's *log* by the child's own fflush +
     * restore dance. Keeping the capture first makes the captured
     * stream unconditionally clean regardless of buffering order.
     */

    /* 2-4. Capture and verify the full range output. */
    buf = capture_range_output(&len);
    if (buf != NULL) {
        lines = split_lines(buf, len, &line_count);
        if (lines == NULL && line_count == 0) {
            printf("FAIL: captured range output was empty\n");
            failures++;
        } else if (lines != NULL) {
            check_line_array(lines, line_count);
            free(lines);
        }
        free(buf);
    }

    /* 1. Known label values (plain stdout, no pipe involved). */
    check_label(0, "FizzBuzz");
    check_label(1, "1");
    check_label(2, "2");
    check_label(3, "Fizz");
    check_label(5, "Buzz");
    check_label(15, "FizzBuzz");
    check_label(30, "FizzBuzz");
    check_label(333, "Fizz");
    check_label(995, "Buzz");
    check_label(999, "Fizz");
    check_label(1000, "Buzz");

    if (failures != 0) {
        printf("%d test(s) FAILED\n", failures);
        return 1;
    }

    printf("ALL TESTS PASSED\n");
    return 0;
}
