#include "latm.h"
#include <string.h>

typedef struct {
    const uint8_t *d;
    size_t bits, pos;
    int err;
} BitReader;

static uint32_t rd(BitReader *b, int n) {
    uint32_t v = 0;
    while (n-- > 0) {
        if (b->pos >= b->bits) { b->err = 1; return 0; }
        v = (v << 1) | ((b->d[b->pos >> 3] >> (7 - (b->pos & 7))) & 1);
        b->pos++;
    }
    return v;
}

static uint32_t latmValue(BitReader *b) {
    int n = (int)rd(b, 2);
    uint32_t v = 0;
    for (int i = 0; i <= n; i++) v = (v << 8) | rd(b, 8);
    return v;
}

static const int kRates[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                             16000, 12000, 11025, 8000, 7350, 0, 0, 0};

static void parseASC(BitReader *b, LatmState *st) {
    st->objectType = (int)rd(b, 5);
    if (st->objectType == 31) st->objectType = 32 + (int)rd(b, 6);
    st->sampleRateIndex = (int)rd(b, 4);
    st->sampleRate = st->sampleRateIndex == 0xF ? (int)rd(b, 24) : kRates[st->sampleRateIndex];
    st->channels = (int)rd(b, 4);
    rd(b, 3);  // GASpecificConfig: frameLengthFlag, dependsOnCoreCoder(=0), extensionFlag(=0)
    st->asc[0] = (uint8_t)((st->objectType << 3) | (st->sampleRateIndex >> 1));
    st->asc[1] = (uint8_t)(((st->sampleRateIndex & 1) << 7) | (st->channels << 3));
}

static int parseStreamMuxConfig(BitReader *b, LatmState *st) {
    st->audioMuxVersion = (int)rd(b, 1);
    int versionA = st->audioMuxVersion ? (int)rd(b, 1) : 0;
    if (versionA) return -1;
    if (st->audioMuxVersion) latmValue(b);           // taraBufferFullness
    int allSame = (int)rd(b, 1);
    st->numSubFrames = (int)rd(b, 6);
    int numProgram = (int)rd(b, 4);
    int numLayer = (int)rd(b, 3);
    if (!allSame || numProgram || numLayer) return -1;
    if (st->audioMuxVersion) {
        uint32_t ascLen = latmValue(b);
        size_t start = b->pos;
        parseASC(b, st);
        size_t used = b->pos - start;
        if (ascLen > used) rd(b, (int)(ascLen - used)); // fill bits (≤ a few bits in practice)
    } else {
        parseASC(b, st);
    }
    if (rd(b, 3) != 0) return -1;                    // frameLengthType must be 0
    rd(b, 8);                                         // latmBufferFullness
    st->otherDataPresent = (int)rd(b, 1);
    if (st->otherDataPresent) {
        if (st->audioMuxVersion) st->otherDataLenBits = latmValue(b);
        else {
            uint32_t v = 0; int esc;
            do { esc = (int)rd(b, 1); v = (v << 8) | rd(b, 8); } while (esc && !b->err);
            st->otherDataLenBits = v;
        }
    }
    if (rd(b, 1)) rd(b, 8);                           // crcCheckPresent / crcCheckSum
    st->haveConfig = !b->err;
    return b->err ? -1 : 0;
}

int latm_parse(LatmState *st, const uint8_t *data, size_t len, LatmFrameFn fn, void *ctx, size_t *consumed) {
    BitReader b = {data, len * 8, 0, 0};
    if (!rd(&b, 1)) {                                 // useSameStreamMux == 0
        LatmState tmp = *st;
        if (parseStreamMuxConfig(&b, &tmp) < 0) return b.err ? -2 : -1;
        *st = tmp;
    } else if (!st->haveConfig) {
        return -1;
    }
    uint8_t frame[8192];
    int count = 0;
    for (int i = 0; i <= st->numSubFrames; i++) {
        size_t flen = 0;
        uint32_t t;
        do { t = rd(&b, 8); flen += t; } while (t == 255 && !b.err);
        if (b.err) return -2;
        if (flen > sizeof frame) return -1;
        if (b.pos + flen * 8 > b.bits) return -2;
        if ((b.pos & 7) == 0) {                       // byte aligned: copy directly
            memcpy(frame, data + (b.pos >> 3), flen);
            b.pos += flen * 8;
        } else {
            for (size_t k = 0; k < flen; k++) frame[k] = (uint8_t)rd(&b, 8);
        }
        if (b.err) return -2;
        if (fn) fn(frame, flen, ctx);
        count++;
    }
    if (st->otherDataPresent) {
        if (b.pos + st->otherDataLenBits > b.bits) return -2;
        b.pos += st->otherDataLenBits;
    }
    if (consumed) *consumed = (b.pos + 7) >> 3;       // ByteAlign()
    return count;
}
