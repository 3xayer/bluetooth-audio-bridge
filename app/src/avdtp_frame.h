// Splitting a byte stream from the AVDTP signaling channel into individual messages.
#pragma once
#include <stddef.h>
#include <stdint.h>

// The signaling channel is a byte stream, so a single read can contain several AVDTP messages
// (e.g. a START command right behind a DELAY_REPORT accept). AVDTP has no length field; the
// length follows from the message type and signal. Variable-length messages (capabilities,
// discovery results, configuration) only occur during setup, where we wait for each reply, so
// they are taken to run to the end of the read.
enum { AVF_CMD = 0, AVF_ACCEPT = 2, AVF_REJECT = 3 };
enum { AVF_DISCOVER = 1, AVF_GET_CAP = 2, AVF_SET_CONF = 3, AVF_GET_CONF = 4, AVF_RECONF = 5, AVF_OPEN = 6,
       AVF_START = 7, AVF_CLOSE = 8, AVF_SUSPEND = 9, AVF_ABORT = 10, AVF_SECURITY = 11, AVF_GET_ALL_CAP = 12,
       AVF_DELAY_REPORT = 13 };

static inline size_t avdtpMessageLength(const uint8_t *b, size_t avail) {
    if (avail < 2) return avail;
    uint8_t pkt = (b[0] >> 2) & 3, type = b[0] & 3, sig = b[1] & 0x3F;
    if (pkt != 0) return avail;   // fragmented messages: not split
    size_t payload;
    switch (type) {
    case AVF_CMD:
        switch (sig) {
        case AVF_DISCOVER: payload = 0; break;
        case AVF_GET_CAP: case AVF_GET_ALL_CAP: case AVF_GET_CONF: case AVF_OPEN: case AVF_CLOSE: case AVF_ABORT: payload = 1; break;
        case AVF_START: case AVF_SUSPEND: payload = 1; break;   // one SEID (we only ever have one stream)
        case AVF_DELAY_REPORT: payload = 3; break;
        default: return avail;                               // SET_CONF, RECONF, SECURITY: variable
        }
        break;
    case AVF_ACCEPT:
        switch (sig) {
        case AVF_DISCOVER: case AVF_GET_CAP: case AVF_GET_ALL_CAP: case AVF_GET_CONF: case AVF_SECURITY: return avail;
        default: payload = 0;
        }
        break;
    case AVF_REJECT:
        payload = (sig == AVF_SET_CONF || sig == AVF_RECONF || sig == AVF_START || sig == AVF_SUSPEND) ? 2 : 1;
        break;
    default:   // general reject
        payload = 0;
    }
    return avail < 2 + payload ? avail : 2 + payload;
}

