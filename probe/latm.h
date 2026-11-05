// Minimal LATM (ISO/IEC 14496-3 §1.7.3) parser for A2DP AAC streams.
// Handles AudioMuxElement(muxConfigPresent=1) with audioMuxVersion 0 or 1 (A=0), a single
// program/layer and frameLengthType 0 — which is what Android's A2DP AAC encoder emits.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int haveConfig;
    int audioMuxVersion;
    int numSubFrames;
    int otherDataPresent;
    uint32_t otherDataLenBits;
    // AudioSpecificConfig
    int objectType;        // 2 = AAC LC
    int sampleRateIndex;   // 4 = 44100
    int sampleRate;
    int channels;
    uint8_t asc[2];        // re-encoded 2-byte AudioSpecificConfig (for decoder magic cookie)
} LatmState;

typedef void (*LatmFrameFn)(const uint8_t *frame, size_t len, void *ctx);

// Parses one AudioMuxElement starting at data. Calls fn for every raw AAC access unit.
// Returns number of frames delivered; -1 on a parse error; -2 if data ends before the element does
// (more bytes needed). On success *consumed (if non-NULL) is the element's byte length.
int latm_parse(LatmState *st, const uint8_t *data, size_t len, LatmFrameFn fn, void *ctx, size_t *consumed);
