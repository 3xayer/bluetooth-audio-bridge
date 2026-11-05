// cc -I../src test_avdtp_frame.c && ./a.out
#include "avdtp_frame.h"
#include <stdio.h>
#include <string.h>

static int fails;
static void split(const char *name, const uint8_t *b, size_t n, const size_t *expect, int count) {
    size_t pos = 0; int i = 0;
    while (pos + 2 <= n) {
        size_t len = avdtpMessageLength(b + pos, n - pos);
        if (i >= count || len != expect[i]) { printf("FAIL %s: msg %d len %zu\n", name, i, len); fails++; return; }
        pos += len; i++;
    }
    if (i != count || pos != n) { printf("FAIL %s: got %d msgs, pos %zu/%zu\n", name, i, pos, n); fails++; return; }
    printf("ok   %s\n", name);
}

int main(void) {
    // DELAY_REPORT accept + START cmd (seid 1) merged
    uint8_t a[] = {0x72, 0x0d, 0x30, 0x07, 0x04};
    split("delay-accept + start", a, sizeof a, (size_t[]){2, 3}, 2);
    // SUSPEND cmd + START cmd
    uint8_t b[] = {0x30, 0x09, 0x04, 0x40, 0x07, 0x04};
    split("suspend + start", b, sizeof b, (size_t[]){3, 3}, 2);
    // single DISCOVER accept (variable) runs to end
    uint8_t c[] = {0x12, 0x01, 0x04, 0x00, 0x08, 0x00, 0x0c, 0x00};
    split("discover accept", c, sizeof c, (size_t[]){8}, 1);
    // OPEN accept + START reject (seid + error)
    uint8_t d[] = {0x52, 0x06, 0x63, 0x07, 0x04, 0x31};
    split("open accept + start reject", d, sizeof d, (size_t[]){2, 4}, 2);
    // CLOSE cmd alone
    uint8_t e[] = {0x80, 0x08, 0x04};
    split("close", e, sizeof e, (size_t[]){3}, 1);
    // DELAY_REPORT cmd from source + START cmd
    uint8_t f[] = {0x10, 0x0d, 0x04, 0x07, 0xd0, 0x20, 0x07, 0x04};
    split("delay-report cmd + start", f, sizeof f, (size_t[]){5, 3}, 2);
    printf(fails ? "%d FAILED\n" : "all passed\n", fails);
    return fails != 0;
}
