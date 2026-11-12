#import "AVRCP.h"
#import "Log.h"
#import <CoreBluetooth/CoreBluetooth.h>

// AVCTP: 1-byte header (label, packet type, C/R, IPID) + 2-byte profile ID, then an AV/C frame.
static const uint16_t kPIDAVRCP = 0x110E;
enum { CT_CONTROL = 0x0, CT_STATUS = 0x1, CT_NOTIFY = 0x3,
       RSP_NOT_IMPLEMENTED = 0x8, RSP_ACCEPTED = 0x9, RSP_REJECTED = 0xA, RSP_STABLE = 0xC, RSP_CHANGED = 0xD, RSP_INTERIM = 0xF };
enum { OP_VENDOR = 0x00, OP_UNIT_INFO = 0x30, OP_SUBUNIT_INFO = 0x31, OP_PASS_THROUGH = 0x7C };
enum { PDU_GET_CAPABILITIES = 0x10, PDU_GET_ELEMENT_ATTRIBUTES = 0x20, PDU_GET_PLAY_STATUS = 0x30,
       PDU_REGISTER_NOTIFICATION = 0x31, PDU_REQUEST_CONTINUING = 0x40, PDU_SET_ABSOLUTE_VOLUME = 0x50 };
enum { EV_PLAYBACK_STATUS = 0x01, EV_TRACK_CHANGED = 0x02, EV_VOLUME_CHANGED = 0x0D };
static const uint8_t kPanel = 0x48;   // subunit type 9 (panel), id 0
static const uint8_t kBTSIG[3] = {0x00, 0x19, 0x58};

// Length of the AV/C frame at the start of p (the L2CAP stream can merge messages), 0 if incomplete.
static size_t avcLength(const uint8_t *p, size_t n) {
    if (n < 3) return 0;
    size_t len;
    switch (p[2]) {
    case OP_PASS_THROUGH: len = n >= 5 ? 5 + p[4] : 0; break;
    case OP_UNIT_INFO: case OP_SUBUNIT_INFO: len = 8; break;
    case OP_VENDOR: len = n >= 10 ? 10 + ((size_t)p[8] << 8 | p[9]) : 0; break;
    default: len = n; break;
    }
    return len && len <= n ? len : 0;
}

@interface BABAVRCP () <NSStreamDelegate>
@property(readwrite, copy) NSString *title, *artist, *album;
@property(readwrite) BABPlayStatus playStatus;
@end

@implementation BABAVRCP {
    CBL2CAPChannel *_channel;
    NSInputStream *_in;
    NSOutputStream *_out;
    NSMutableData *_rx, *_fragment;
    NSMutableArray<NSData *> *_txQueue;
    BOOL _txWaiting;
    uint8_t _label;
    int _volumeLabel;   // label of the source's pending VOLUME_CHANGED registration, -1 = none
    BOOL _closed;
}

- (instancetype)initWithChannel:(CBL2CAPChannel *)channel {
    if ((self = [super init])) {
        _channel = channel;
        _rx = [NSMutableData data];
        _txQueue = [NSMutableArray array];
        _volumeLabel = -1;
        _volume = 1.0f;
        _playStatus = BABPlayStatusUnknown;
        _in = channel.inputStream; _out = channel.outputStream;
        _in.delegate = self; _out.delegate = self;
        [_in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [_out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [_in open]; [_out open];
        BABLog(@"AVRCP channel open");
        [self registerFor:EV_PLAYBACK_STATUS];
        [self registerFor:EV_TRACK_CHANGED];
    }
    return self;
}

- (void)close {
    if (_closed) return;
    _closed = YES;
    _in.delegate = nil; _out.delegate = nil;
    [_in close]; [_out close];
    _in = nil; _out = nil; _channel = nil;
}

#pragma mark - sending

- (void)sendAVC:(const uint8_t *)avc len:(size_t)n label:(uint8_t)label response:(BOOL)response {
    if (_closed || !_out) return;
    uint8_t b[512];
    if (n + 3 > sizeof b) return;
    b[0] = (uint8_t)(label << 4) | (response ? 0x02 : 0x00);
    b[1] = kPIDAVRCP >> 8; b[2] = kPIDAVRCP & 0xFF;
    memcpy(b + 3, avc, n);
    [_txQueue addObject:[NSData dataWithBytes:b length:n + 3]];
    [self drain];
}

// The channel is a byte stream: messages written back to back reach the source as one L2CAP packet,
// which it rejects as a single invalid command. So leave a short gap between messages.
- (void)drain {
    if (_txWaiting || _txQueue.count == 0 || _closed) return;
    NSData *m = _txQueue.firstObject;
    [_txQueue removeObjectAtIndex:0];
    [_out write:m.bytes maxLength:m.length];
    _txWaiting = YES;
    __weak BABAVRCP *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        BABAVRCP *s = ws;
        if (!s) return;
        s->_txWaiting = NO;
        [s drain];
    });
}

- (uint8_t)nextLabel { _label = (_label + 1) & 0x0F; return _label; }

// Vendor-dependent (Bluetooth SIG) frame: ctype, panel, opcode, company, PDU, packet type, length, params.
- (void)sendVendor:(uint8_t)ctype pdu:(uint8_t)pdu params:(const uint8_t *)p len:(size_t)n label:(uint8_t)label response:(BOOL)response {
    uint8_t f[256];
    if (n + 10 > sizeof f) return;
    f[0] = ctype; f[1] = kPanel; f[2] = OP_VENDOR;
    memcpy(f + 3, kBTSIG, 3);
    f[6] = pdu; f[7] = 0; f[8] = (uint8_t)(n >> 8); f[9] = (uint8_t)n;
    if (n) memcpy(f + 10, p, n);
    [self sendAVC:f len:n + 10 label:label response:response];
}

- (void)registerFor:(uint8_t)event {
    uint8_t p[5] = {event, 0, 0, 0, 0};
    [self sendVendor:CT_NOTIFY pdu:PDU_REGISTER_NOTIFICATION params:p len:5 label:[self nextLabel] response:NO];
}

- (void)requestTitle {
    uint8_t p[8 + 1 + 12] = {0};   // identifier 0 = currently playing; title, artist, album
    p[8] = 3;
    p[12] = 1; p[16] = 2; p[20] = 3;
    [self sendVendor:CT_STATUS pdu:PDU_GET_ELEMENT_ATTRIBUTES params:p len:sizeof p label:[self nextLabel] response:NO];
}

- (void)sendKey:(BABAVRCPKey)key {
    BABLog(@"AVRCP key 0x%02x", key);
    uint8_t press[5] = {CT_CONTROL, kPanel, OP_PASS_THROUGH, key, 0};
    [self sendAVC:press len:5 label:[self nextLabel] response:NO];
    uint8_t release[5] = {CT_CONTROL, kPanel, OP_PASS_THROUGH, (uint8_t)(key | 0x80), 0};
    [self sendAVC:release len:5 label:[self nextLabel] response:NO];
}

- (void)setVolume:(float)volume {
    if (fabsf(volume - _volume) < 0.5f / 127) return;   // unchanged (e.g. the source just set it)
    _volume = volume;
    if (_volumeLabel < 0) return;
    uint8_t p[2] = {EV_VOLUME_CHANGED, (uint8_t)lroundf(fminf(fmaxf(volume, 0), 1) * 127)};
    [self sendVendor:RSP_CHANGED pdu:PDU_REGISTER_NOTIFICATION params:p len:2 label:(uint8_t)_volumeLabel response:YES];
    _volumeLabel = -1;
}

#pragma mark - receiving

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (s == _in && (e & NSStreamEventHasBytesAvailable)) {
        uint8_t b[1024];
        NSInteger n = [_in read:b maxLength:sizeof b];
        if (n > 0) [_rx appendBytes:b length:(NSUInteger)n];
        const uint8_t *p = _rx.bytes;
        size_t have = _rx.length, pos = 0;
        while (have - pos >= 6) {
            size_t len = avcLength(p + pos + 3, have - pos - 3);
            if (!len) break;
            [self handle:p + pos avc:p + pos + 3 len:len];
            pos += 3 + len;
        }
        [_rx replaceBytesInRange:NSMakeRange(0, pos) withBytes:NULL length:0];
    }
    if (e & (NSStreamEventErrorOccurred | NSStreamEventEndEncountered)) {
        BABLog(@"AVRCP channel closed");
        [self close];
        if ([self.delegate respondsToSelector:@selector(avrcpDidClose:)]) [self.delegate avrcpDidClose:self];
    }
}

- (void)handle:(const uint8_t *)hdr avc:(const uint8_t *)a len:(size_t)n {
    uint8_t label = hdr[0] >> 4;
    BOOL response = (hdr[0] >> 1) & 1;
    if (((hdr[0] >> 2) & 3) != 0) return;                 // fragmented AVCTP: not used at these sizes
    if ((hdr[1] << 8 | hdr[2]) != kPIDAVRCP) return;
    if (response) [self handleResponse:a len:n];
    else [self handleCommand:a len:n label:label];
}

- (void)handleResponse:(const uint8_t *)a len:(size_t)n {
    uint8_t ctype = a[0] & 0x0F;
    if (a[2] != OP_VENDOR || n < 10) return;
    uint8_t pdu = a[6], packetType = a[7] & 3;
    size_t plen = (size_t)a[8] << 8 | a[9];
    const uint8_t *p = a + 10;
    if (plen > n - 10) return;
    if (ctype == RSP_REJECTED || ctype == RSP_NOT_IMPLEMENTED) {
        NSMutableString *hex = [NSMutableString string];
        for (size_t i = 0; i < n && i < 24; i++) [hex appendFormat:@"%02x ", a[i]];
        BABLog(@"AVRCP PDU 0x%02x refused (0x%x): %@", pdu, ctype, hex);
        return;
    }
    // Long responses (e.g. titles) come in parts: collect them and ask for the rest.
    if (packetType == 1 || packetType == 2 || packetType == 3) {
        if (packetType == 1) _fragment = [NSMutableData data];
        [_fragment appendBytes:p length:plen];
        if (packetType != 3) {
            uint8_t q = pdu;
            [self sendVendor:CT_CONTROL pdu:PDU_REQUEST_CONTINUING params:&q len:1 label:[self nextLabel] response:NO];
            return;
        }
        NSData *all = _fragment;
        _fragment = nil;
        [self handlePDU:pdu ctype:ctype params:all.bytes len:all.length];
        return;
    }
    [self handlePDU:pdu ctype:ctype params:p len:plen];
}

- (void)handlePDU:(uint8_t)pdu ctype:(uint8_t)ctype params:(const uint8_t *)p len:(size_t)n {
    if (pdu == PDU_REGISTER_NOTIFICATION && n >= 2) BABLog(@"AVRCP event 0x%02x %@: %02x", p[0], ctype == RSP_INTERIM ? @"interim" : @"changed", p[1]);
    if (pdu == PDU_REGISTER_NOTIFICATION && n >= 2) {
        if (p[0] == EV_PLAYBACK_STATUS) {
            BABPlayStatus st = p[1] <= 2 ? (BABPlayStatus)p[1] : BABPlayStatusUnknown;
            if (st != self.playStatus) { self.playStatus = st; [self.delegate avrcpDidUpdateMedia:self]; }
        } else if (p[0] == EV_TRACK_CHANGED) {
            [self requestTitle];
        }
        if (ctype == RSP_CHANGED) [self registerFor:p[0]];   // notifications fire once; register again
    } else if (pdu == PDU_GET_ELEMENT_ATTRIBUTES && n >= 1) {
        NSString *title = nil, *artist = nil, *album = nil;
        size_t pos = 1;
        for (int i = 0; i < p[0] && pos + 8 <= n; i++) {
            uint32_t attr = (uint32_t)p[pos] << 24 | p[pos + 1] << 16 | p[pos + 2] << 8 | p[pos + 3];
            size_t len = (size_t)p[pos + 6] << 8 | p[pos + 7];
            pos += 8;
            if (pos + len > n) break;
            NSString *v = [[NSString alloc] initWithBytes:p + pos length:len encoding:NSUTF8StringEncoding];
            if (attr == 1) title = v; else if (attr == 2) artist = v; else if (attr == 3) album = v;
            pos += len;
        }
        if (![title isEqualToString:self.title] || ![artist isEqualToString:self.artist]) BABLog(@"Now playing: %@ – %@", title, artist);
        self.title = title.length ? title : nil;
        self.artist = artist.length ? artist : nil;
        self.album = album.length ? album : nil;
        [self.delegate avrcpDidUpdateMedia:self];
    }
}

// Commands from the source, which acts as controller towards us (unit info and absolute volume).
- (void)handleCommand:(const uint8_t *)a len:(size_t)n label:(uint8_t)label {
    uint8_t op = a[2];
    if (op == OP_UNIT_INFO || op == OP_SUBUNIT_INFO) {
        uint8_t r[8] = {RSP_STABLE, 0xFF, op, 0x07, kPanel, kBTSIG[0], kBTSIG[1], kBTSIG[2]};
        if (op == OP_SUBUNIT_INFO) { r[4] = kPanel; r[5] = r[6] = r[7] = 0xFF; }
        [self sendAVC:r len:8 label:label response:YES];
        return;
    }
    if (op == OP_PASS_THROUGH && n >= 5) {
        uint8_t r[8];
        memcpy(r, a, MIN(n, sizeof r));
        r[0] = RSP_ACCEPTED;
        [self sendAVC:r len:MIN(n, sizeof r) label:label response:YES];
        return;
    }
    if (op == OP_VENDOR && n >= 10) {
        uint8_t pdu = a[6];
        const uint8_t *p = a + 10;
        size_t plen = MIN((size_t)a[8] << 8 | a[9], n - 10);
        if (pdu == PDU_GET_CAPABILITIES && plen >= 1) {
            BABLog(@"AVRCP: source asks for capabilities (0x%02x)", p[0]);
            if (p[0] == 0x02) { uint8_t r[5] = {0x02, 1, kBTSIG[0], kBTSIG[1], kBTSIG[2]};
                [self sendVendor:RSP_STABLE pdu:pdu params:r len:5 label:label response:YES]; return; }
            if (p[0] == 0x03) { uint8_t r[3] = {0x03, 1, EV_VOLUME_CHANGED};
                [self sendVendor:RSP_STABLE pdu:pdu params:r len:3 label:label response:YES]; return; }
        }
        if (pdu == PDU_REGISTER_NOTIFICATION && plen >= 1 && p[0] == EV_VOLUME_CHANGED) {
            _volumeLabel = label;
            uint8_t r[2] = {EV_VOLUME_CHANGED, (uint8_t)lroundf(fminf(fmaxf(_volume, 0), 1) * 127)};
            [self sendVendor:RSP_INTERIM pdu:pdu params:r len:2 label:label response:YES];
            BABLog(@"AVRCP: source uses absolute volume");
            return;
        }
        if (pdu == PDU_SET_ABSOLUTE_VOLUME && plen >= 1) {
            uint8_t v = p[0] & 0x7F;
            _volume = v / 127.0f;
            [self sendVendor:RSP_ACCEPTED pdu:pdu params:&v len:1 label:label response:YES];
            BABLog(@"AVRCP: absolute volume %d/127", v);
            if ([self.delegate respondsToSelector:@selector(avrcp:didSetVolume:)]) [self.delegate avrcp:self didSetVolume:_volume];
            return;
        }
    }
    uint8_t r[256];
    size_t m = MIN(n, sizeof r);
    memcpy(r, a, m);
    r[0] = RSP_NOT_IMPLEMENTED;
    [self sendAVC:r len:m label:label response:YES];
}

@end
