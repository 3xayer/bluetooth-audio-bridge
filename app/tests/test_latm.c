// LATM parser test using a real AudioMuxElement header captured from a Fire TV (AAC LC, 44.1 kHz,
// stereo, audioMuxVersion 1) with a synthetic 648-byte payload.
#include "latm.h"
#include <stdio.h>
#include <string.h>

static int fails;
static size_t gotLen;
static void onFrame(const uint8_t *f, size_t n, void *ctx) { gotLen = n; (void)f; (void)ctx; }

int main(void) {
    uint8_t el[13 + 648 + 4];
    const uint8_t hdr[] = {0x47, 0xfc, 0x00, 0x00, 0xb0, 0x90, 0x80, 0x03, 0x00, 0xff, 0xff, 0x8a};
    memcpy(el, hdr, sizeof hdr);
    // payload: 255+255+138 = 648 bytes, starting at bit offset 12*8 - 4? Build by parsing instead:
    memset(el + sizeof hdr, 0x5a, sizeof el - sizeof hdr);
    LatmState st = {0};
    size_t used = 0;
    int r = latm_parse(&st, el, sizeof el, onFrame, NULL, &used);
    int ok = r == 1 && st.objectType == 2 && st.sampleRate == 44100 && st.channels == 2 && gotLen == 648 &&
             st.asc[0] == 0x12 && st.asc[1] == 0x10 && used > 648 && used <= sizeof el;
    printf("%s full element: r=%d aot=%d rate=%d ch=%d frame=%zu used=%zu\n", ok ? "ok  " : "FAIL", r, st.objectType,
           st.sampleRate, st.channels, gotLen, used);
    fails += !ok;

    // truncated element must ask for more data (-2), not fail or overrun
    LatmState st2 = {0};
    r = latm_parse(&st2, el, 300, onFrame, NULL, &used);
    ok = r == -2;
    printf("%s truncated element -> %d (want -2)\n", ok ? "ok  " : "FAIL", r);
    fails += !ok;

    printf(fails ? "%d FAILED\n" : "all passed\n", fails);
    return fails != 0;
}
