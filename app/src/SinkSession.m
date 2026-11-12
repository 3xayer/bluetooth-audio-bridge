#import "SinkSession.h"
#import "AACPlayer.h"
#import "Log.h"
#import "AVRCP.h"
#import "LinkPriority.h"
#include "latm.h"
#include "oi_codec_sbc.h"
#include "avdtp_frame.h"
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

extern char **environ;

// Private API: the public IOBluetoothL2CAPChannel path cannot open channels on recent macOS, but
// CoreBluetooth's classic peer object can. Signatures as observed on macOS 15–27.
@interface IOBluetoothDevice (BABPrivate)
- (id)classicPeer;
@end
@protocol BABClassicPeer
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *ch, long code))cb;
- (id)openL2CAPChannel:(unsigned long)psm;
@end

static const unsigned long kPSM_AVDTP = 0x19, kPSM_AVCTP = 0x17;
enum { AV_DISCOVER = 1, AV_GET_CAP = 2, AV_SET_CONF = 3, AV_GET_CONF = 4, AV_RECONF = 5, AV_OPEN = 6,
       AV_START = 7, AV_CLOSE = 8, AV_SUSPEND = 9, AV_ABORT = 10, AV_SECURITY = 11,
       AV_GET_ALL_CAP = 12, AV_DELAY_REPORT = 13 };
enum { MSG_CMD = 0, MSG_GEN_REJECT = 1, MSG_ACCEPT = 2, MSG_REJECT = 3 };
static const uint8_t kLocalSEID = 1;
static const uint8_t kCodecSBC = 0x00, kCodecAAC = 0x02;

// SBC frame length from its header (A2DP spec 12.9); -1 if this isn't a frame header.
static int sbcFrameLength(const uint8_t *f, size_t n) {
    if (n < 3 || f[0] != 0x9C) return -1;
    int blocks = 4 * (((f[1] >> 4) & 3) + 1), mode = (f[1] >> 2) & 3, subbands = (f[1] & 1) ? 8 : 4, bitpool = f[2];
    int ch = mode == 0 ? 1 : 2;
    int bits = mode < 2 ? blocks * ch * bitpool : (mode == 3 ? subbands : 0) + blocks * bitpool;
    return 4 + (4 * subbands * ch) / 8 + (bits + 7) / 8;
}

// Length of one SBC media payload (1-byte header + frames): 0 ok, -2 incomplete, -1 invalid.
// The media socket is a byte stream, so this is what separates merged packets.
static int sbcPayloadLength(const uint8_t *p, size_t n, size_t *len) {
    if (n < 4) return -2;
    int frames = p[0] & 0x0F;
    if (frames == 0 || (p[0] & 0x80)) return -1;   // fragmented frames aren't used at A2DP packet sizes
    size_t off = 1;
    for (int i = 0; i < frames; i++) {
        if (n - off < 3) return -2;
        int fl = sbcFrameLength(p + off, n - off);
        if (fl < 0) return -1;
        off += (size_t)fl;
        if (off > n) return -2;
    }
    *len = off;
    return 0;
}
// What we tell a source that asks about our endpoint: audio sink, AAC LC 44.1/48 kHz stereo + delay reporting.
static const uint8_t kSinkCaps[] = {0x01, 0x00, 0x07, 0x08, 0x00, 0x02, 0x80, 0x01, 0x8C, 0x84, 0xE2, 0x00, 0x08, 0x00};

static NSString *sigName(int s) {
    static NSString *n[] = {@"?", @"DISCOVER", @"GET_CAP", @"SET_CONF", @"GET_CONF", @"RECONF", @"OPEN",
                            @"START", @"CLOSE", @"SUSPEND", @"ABORT", @"SECURITY", @"GET_ALL_CAP", @"DELAY_REPORT"};
    return (s >= 1 && s <= 13) ? n[s] : [NSString stringWithFormat:@"sig%d", s];
}
static NSString *hexs(const uint8_t *b, size_t n) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n && i < 32; i++) [s appendFormat:@"%02x ", b[i]];
    return s;
}

typedef struct { uint8_t buf[4][4096]; size_t len[4]; int count; } FrameBatch;
static void collectFrame(const uint8_t *f, size_t n, void *ctx) {
    FrameBatch *b = ctx;
    if (b->count < 4 && n <= sizeof b->buf[0]) { memcpy(b->buf[b->count], f, n); b->len[b->count++] = n; }
}

@interface SinkSession () <NSStreamDelegate>
@property(nonatomic, readwrite) SinkState state;
@property(readwrite, copy) NSString *endReason;
@property(readwrite) BOOL everConnected;
@property(readwrite) double bitrateKbps, delayMs;
@property(readwrite) uint64_t underruns, lostPackets;
@property(readwrite, copy) NSString *codecDescription;
@property(readwrite, strong) BABAVRCP *avrcp;
@property(atomic, strong) AACPlayer *player;   // shared by the media thread and the main thread
@end

@implementation SinkSession {
    IOBluetoothDevice *_dev;
    id<BABClassicPeer> _peer;
    CBL2CAPChannel *_sigCh;
    NSInputStream *_in;
    NSOutputStream *_out;
    uint8_t _label, _remoteSEID;
    NSMutableArray<NSNumber *> *_pendingSEIDs;
    BOOL _configured, _openSent, _opened, _ending;
    pid_t _helperPID;
    NSString *_sockPath;
    int _mediaFD;
    NSTimer *_tick, *_connectTimeout, *_signalingRetry;
    int _signalingAttempts;
    id<NSObject> _activity;   // keeps App Nap / timer coalescing away while connected
    int _ticks;
    double _reportedDelayMs;
    double _lastTickTime;
    // media thread state
    LatmState _latm;
    uint8_t _codec;                 // kCodecAAC or kCodecSBC, chosen in SET_CONF
    int _sampleRate;                // configured rate (SBC; AAC takes it from the stream)
    int _sbcSEID;                   // remote SBC endpoint seen while looking for AAC (0 = none)
    uint8_t _sbcCaps[4];
    BOOL _aac48k;                   // the AAC endpoint offers 48 kHz
    OI_CODEC_SBC_DECODER_CONTEXT _sbcContext;
    uint32_t _sbcData[CODEC_DATA_WORDS(2, SBC_CODEC_FAST_FILTER_BUFFERS)];
    volatile BOOL _playerNeedsRestart;
    uint64_t _mediaBytes, _lastBytes, _mediaPackets;
}

- (instancetype)initWithAddress:(NSString *)address {
    if ((self = [super init])) {
        _address = [address copy];
        _volume = 1.0f;
        _mediaFD = -1;
        _state = SinkStateIdle;
    }
    return self;
}

- (void)setState:(SinkState)state {
    if (_state == state) return;
    _state = state;
    if (state == SinkStateReady || state == SinkStateStreaming) _everConnected = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate sinkSessionDidChangeState:self]; });
}

- (void)setVolume:(float)volume {
    _volume = volume;
    self.player.volume = volume;   // gain on the received audio; the source's volume is AppDelegate's business
}

- (void)setOutputDeviceUID:(NSString *)uid {
    _outputDeviceUID = [uid copy];
    _playerNeedsRestart = YES;   // picked up by the media thread before the next frame
}

#pragma mark - lifecycle

- (void)start {
    _dev = [IOBluetoothDevice deviceWithAddressString:self.address];
    if (!_dev.isPaired) { [self endWithReason:@"Device is not paired with this Mac"]; return; }
    _peer = [_dev classicPeer];
    if (!_peer) { [self endWithReason:@"Bluetooth peer unavailable"]; return; }
    self.state = SinkStateConnecting;
    __weak SinkSession *ws = self;
    _connectTimeout = [NSTimer scheduledTimerWithTimeInterval:25 repeats:NO block:^(NSTimer *t) {
        if (ws.state == SinkStateConnecting) [ws endWithReason:@"Timed out connecting"];
    }];
    BABLog(@"Connecting to %@ (%@), link up=%d", _dev.name, self.address, _dev.isConnected);
    if (_dev.isConnected) {
        [self openSignaling];
    } else {
        // Opening an L2CAP channel through the classic peer does not page a disconnected device,
        // so bring the baseband link up first.
        IOReturn r = [_dev openConnection:self];
        if (r != kIOReturnSuccess) [self endWithReason:[NSString stringWithFormat:@"Could not start connection (0x%x)", r]];
    }
}

// IOBluetoothDevice openConnection: callback
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (_ending) return;
    if (status != kIOReturnSuccess) {
        [self endWithReason:status == 0x04 || status == (IOReturn)0xe00002d6 ? @"Device not reachable (off or out of range)"
                                    : [NSString stringWithFormat:@"Could not reach device (0x%x)", status]];
        return;
    }
    BABLog(@"Link up");
    [self openSignaling];
}

static const int kMaxSignalingAttempts = 5;

// Open requests can be dropped or refused right after the link comes up, so retry a few times.
- (void)openSignaling {
    if (_ending || _sigCh) return;
    _signalingAttempts++;
    if (_signalingAttempts > 1) BABLog(@"Retrying signaling channel (attempt %d)", _signalingAttempts);
    _peer = [_dev classicPeer] ?: _peer;
    __weak SinkSession *ws = self;
    [_peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ch.PSM == kPSM_AVCTP) [ws avrcpOpened:ch];
            else [ws signalingOpened:ch code:code];
        });
    }];
    [_peer openL2CAPChannel:kPSM_AVDTP];
    [_signalingRetry invalidate];
    _signalingRetry = nil;
    if (_signalingAttempts < kMaxSignalingAttempts)
        _signalingRetry = [NSTimer scheduledTimerWithTimeInterval:3 repeats:NO block:^(NSTimer *t) { [ws openSignaling]; }];
}

- (void)stop {
    if (_ending || self.state == SinkStateEnded) return;
    if (_opened && _out) {
        uint8_t s = (uint8_t)(_remoteSEID << 2);
        [self cmd:AV_CLOSE payload:&s len:1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self endWithReason:@"Stopped"];
        });
    } else {
        [self endWithReason:@"Stopped"];
    }
}

- (void)endWithReason:(NSString *)reason {
    if (_ending) return;
    _ending = YES;
    BABLog(@"Session ended: %@", reason);
    self.endReason = reason;
    [BABLinkPriority.shared disable];
    [self.avrcp close];
    [_tick invalidate]; _tick = nil;
    [_connectTimeout invalidate]; _connectTimeout = nil;
    [_signalingRetry invalidate]; _signalingRetry = nil;
    _in.delegate = nil; _out.delegate = nil;
    [_in close]; [_out close];
    _in = nil; _out = nil; _sigCh = nil;
    [_peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {}];
    if (_helperPID > 0) {
        pid_t helper = _helperPID;
        _helperPID = 0;
        kill(helper, SIGTERM);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ waitpid(helper, NULL, 0); });
    }
    if (_sockPath) unlink(_sockPath.fileSystemRepresentation);
    if (_mediaFD >= 0) shutdown(_mediaFD, SHUT_RDWR);   // media thread closes it and stops the player
    if (_activity) { [NSProcessInfo.processInfo endActivity:_activity]; _activity = nil; }
    self.state = SinkStateEnded;
}

#pragma mark - signaling

- (void)signalingOpened:(CBL2CAPChannel *)ch code:(long)code {
    if (_ending || _sigCh) return;
    if (!ch) {
        BABLog(@"Signaling channel failed (code %ld, attempt %d)", code, _signalingAttempts);
        if (_signalingAttempts >= kMaxSignalingAttempts)
            [self endWithReason:[NSString stringWithFormat:@"Could not reach device (code %ld)", code]];
        return;
    }
    [_signalingRetry invalidate]; _signalingRetry = nil;
    _sigCh = ch;
    _in = ch.inputStream; _out = ch.outputStream;
    _in.delegate = self; _out.delegate = self;
    [_in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [_out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [_in open]; [_out open];
    BABLog(@"Signaling channel open");
    [self cmd:AV_DISCOVER payload:NULL len:0];
    // Take the remote-control channel before the source opens one to macOS (which would keep it).
    if (![NSUserDefaults.standardUserDefaults objectForKey:@"avrcpEnabled"] || [NSUserDefaults.standardUserDefaults boolForKey:@"avrcpEnabled"])
        [_peer openL2CAPChannel:kPSM_AVCTP];
}

- (void)avrcpOpened:(CBL2CAPChannel *)ch {
    if (_ending || self.avrcp) return;
    BABAVRCP *a = [[BABAVRCP alloc] initWithChannel:ch];
    self.avrcp = a;
    if ([self.delegate respondsToSelector:@selector(sinkSessionDidOpenAVRCP:)]) [self.delegate sinkSessionDidOpenAVRCP:self];
}

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (s == _in && (e & NSStreamEventHasBytesAvailable)) {
        uint8_t b[1024];
        NSInteger n = [_in read:b maxLength:sizeof b];
        size_t pos = 0;
        while (n > 0 && pos + 2 <= (size_t)n && !_ending) {
            size_t len = avdtpMessageLength(b + pos, (size_t)n - pos);
            if (pos > 0) BABLog(@"(split merged AVDTP messages)");
            [self handle:b + pos len:len];
            pos += len;
        }
    }
    if (e & (NSStreamEventErrorOccurred | NSStreamEventEndEncountered)) {
        [self endWithReason:(e & NSStreamEventErrorOccurred) ? @"Connection lost" : @"Device closed the connection"];
    }
}

- (void)send:(uint8_t)sig type:(uint8_t)type label:(uint8_t)lbl payload:(const uint8_t *)p len:(size_t)n {
    uint8_t b[128];
    b[0] = (uint8_t)(lbl << 4) | type;
    b[1] = sig;
    if (n) memcpy(b + 2, p, n);
    [_out write:b maxLength:n + 2];
    BABLog(@"TX %@ %@: %@", sigName(sig), type == MSG_CMD ? @"cmd" : type == MSG_ACCEPT ? @"accept" : @"reject", hexs(b, n + 2));
}

- (void)cmd:(uint8_t)sig payload:(const uint8_t *)p len:(size_t)n {
    _label = (_label + 1) & 0x0F;
    [self send:sig type:MSG_CMD label:_label payload:p len:n];
}

- (void)handle:(const uint8_t *)b len:(size_t)n {
    uint8_t lbl = b[0] >> 4, pkt = (b[0] >> 2) & 3, type = b[0] & 3, sig = b[1] & 0x3F;
    BABLog(@"RX %@ %@: %@", sigName(sig),
           type == MSG_CMD ? @"cmd" : type == MSG_ACCEPT ? @"accept" : type == MSG_REJECT ? @"REJECT" : @"GEN-REJECT", hexs(b, n));
    if (pkt != 0) return;
    const uint8_t *p = b + 2;
    size_t pl = n - 2;
    if (type == MSG_CMD) { [self remoteCommand:sig label:lbl payload:p len:pl]; return; }
    if (type != MSG_ACCEPT) {
        if (sig == AV_DELAY_REPORT && _configured && !_openSent) { [self sendOpen]; return; }
        if (sig == AV_SET_CONF || sig == AV_OPEN || sig == AV_DISCOVER)
            [self endWithReason:[NSString stringWithFormat:@"Device rejected %@", sigName(sig)]];
        return;
    }
    switch (sig) {
    case AV_DISCOVER:
        _pendingSEIDs = [NSMutableArray array];
        for (size_t i = 0; i + 1 < pl; i += 2) {
            uint8_t seid = p[i] >> 2, inUse = (p[i] >> 1) & 1, media = p[i + 1] >> 4, tsep = (p[i + 1] >> 3) & 1;
            if (media == 0 && tsep == 0 && !inUse) [_pendingSEIDs addObject:@(seid)];
        }
        [self queryNextEndpoint];
        break;
    case AV_GET_CAP: case AV_GET_ALL_CAP: {
        BOOL aac = NO;
        for (size_t i = 0; i + 1 < pl && i + 2 + p[i + 1] <= pl; i += 2 + p[i + 1]) {
            if (p[i] != 7 || p[i + 1] < 2) continue;   // media codec capability
            if (p[i + 3] == kCodecAAC) { aac = YES; _aac48k = p[i + 1] >= 5 && (p[i + 6] & 0x80); }
            if (p[i + 3] == kCodecSBC && p[i + 1] >= 6 && !_sbcSEID) { _sbcSEID = _remoteSEID; memcpy(_sbcCaps, p + i + 4, 4); }
        }
        if (_configured) break;
        // Diagnostics: `defaults write local.bluetooth-audio-bridge sbcForce -bool YES` skips AAC (with sbcEnabled).
        if (aac && ![NSUserDefaults.standardUserDefaults boolForKey:@"sbcForce"]) [self configureAAC];
        else [self queryNextEndpoint];
        break;
    }
    case AV_SET_CONF:
        _configured = YES;
        [self sendDelayReport:200.0];   // initial estimate; OPEN follows its response
        break;
    case AV_DELAY_REPORT:
        if (!_openSent) [self sendOpen];
        break;
    case AV_OPEN:
        _opened = YES;
        [self openTransport];
        break;
    default: break;
    }
}

- (void)queryNextEndpoint {
    if (_pendingSEIDs.count == 0) {
        if (_sbcSEID && [NSUserDefaults.standardUserDefaults boolForKey:@"sbcEnabled"]) { [self configureSBC]; return; }
        [self endWithReason:_sbcSEID ? @"Device only offers SBC (turn on SBC in the menu)" : @"Device offers no AAC audio source"];
        return;
    }
    _remoteSEID = _pendingSEIDs.firstObject.unsignedCharValue;
    [_pendingSEIDs removeObjectAtIndex:0];
    uint8_t s = (uint8_t)(_remoteSEID << 2);
    [self cmd:AV_GET_ALL_CAP payload:&s len:1];
}

// 48 kHz when the source offers it: frames are shorter, so ~9% more bit rate fits the 672-byte packets,
// and phones (which mix at 48 kHz) don't have to resample. `aacSampleRate` = 44100 forces 44.1 kHz.
- (BOOL)use48k:(BOOL)offered {
    return offered && [NSUserDefaults.standardUserDefaults integerForKey:@"aacSampleRate"] != 44100;
}

- (void)configureAAC {
    // Default 320 kbit/s; the source caps it to what fits the packet size (~225-245 kbit/s).
    NSInteger kbps = [NSUserDefaults.standardUserDefaults integerForKey:@"aacBitrate"];
    uint32_t bps = (uint32_t)((kbps >= 64 && kbps <= 320) ? kbps : 320) * 1000;
    BOOL r48 = [self use48k:_aac48k];
    uint8_t conf[] = {(uint8_t)(_remoteSEID << 2), (uint8_t)(kLocalSEID << 2),
                      0x01, 0x00,                 // media transport
                      0x07, 0x08, 0x00, 0x02,     // audio, MPEG-2/4 AAC
                      0x80,                       // MPEG-2 AAC LC
                      r48 ? 0x00 : 0x01, r48 ? 0x84 : 0x04,   // 48 or 44.1 kHz, stereo
                      (uint8_t)(bps >> 16 & 0x7F), (uint8_t)(bps >> 8), (uint8_t)bps,   // CBR, bit rate
                      0x08, 0x00};                // delay reporting
    _codec = kCodecAAC;
    _sampleRate = r48 ? 48000 : 44100;
    self.codecDescription = r48 ? @"AAC 48 kHz" : @"AAC 44.1 kHz";
    BABLog(@"Requesting AAC %d Hz at %u kbit/s", _sampleRate, bps / 1000);
    [self cmd:AV_SET_CONF payload:conf len:sizeof conf];
}

// Fallback for sources without AAC (only when turned on): the best SBC the source allows.
- (void)configureSBC {
    _remoteSEID = (uint8_t)_sbcSEID;
    const uint8_t *c = _sbcCaps;
    BOOL r48 = [self use48k:(c[0] & 0x10) != 0];
    uint8_t freq = r48 ? 0x10 : 0x20;
    uint8_t mode = (c[0] & 0x01) ? 0x01 : (c[0] & 0x02) ? 0x02 : (c[0] & 0x04) ? 0x04 : 0x08;   // joint, stereo, dual, mono
    uint8_t blocks = (c[1] & 0x10) ? 0x10 : (c[1] & 0x20) ? 0x20 : (c[1] & 0x40) ? 0x40 : 0x80; // 16, 12, 8, 4
    uint8_t bands = (c[1] & 0x04) ? 0x04 : 0x08;                                                // 8, 4
    uint8_t alloc = (c[1] & 0x01) ? 0x01 : 0x02;                                                // loudness, SNR
    uint8_t minBP = MAX(2, c[2]), maxBP = MAX(minBP, c[3]);
    uint8_t conf[] = {(uint8_t)(_remoteSEID << 2), (uint8_t)(kLocalSEID << 2),
                      0x01, 0x00,
                      0x07, 0x06, 0x00, kCodecSBC,
                      (uint8_t)(freq | mode), (uint8_t)(blocks | bands | alloc), minBP, maxBP,
                      0x08, 0x00};
    _codec = kCodecSBC;
    _sampleRate = r48 ? 48000 : 44100;
    self.codecDescription = [NSString stringWithFormat:@"SBC %s kHz", r48 ? "48" : "44.1"];
    OI_CODEC_SBC_DecoderReset(&_sbcContext, _sbcData, sizeof _sbcData, 2, 2, FALSE);
    BABLog(@"Requesting SBC %d Hz, bitpool %d-%d (source offers %02x %02x %02x %02x)", _sampleRate, minBP, maxBP, c[0], c[1], c[2], c[3]);
    [self cmd:AV_SET_CONF payload:conf len:sizeof conf];
}

- (void)sendOpen {
    _openSent = YES;
    uint8_t s = (uint8_t)(_remoteSEID << 2);
    [self cmd:AV_OPEN payload:&s len:1];
}

- (void)sendDelayReport:(double)ms {
    uint16_t d = (uint16_t)lround(ms * 10);   // unit: 1/10 ms
    uint8_t pl[] = {(uint8_t)(_remoteSEID << 2), (uint8_t)(d >> 8), (uint8_t)d};
    [self cmd:AV_DELAY_REPORT payload:pl len:sizeof pl];
    _reportedDelayMs = ms;
}

// Commands the source sends to us.
- (void)remoteCommand:(uint8_t)sig label:(uint8_t)lbl payload:(const uint8_t *)p len:(size_t)n {
    switch (sig) {
    case AV_DISCOVER: {
        uint8_t sep[] = {(uint8_t)(kLocalSEID << 2), 0x08};   // audio, SINK
        [self send:sig type:MSG_ACCEPT label:lbl payload:sep len:2];
        break;
    }
    case AV_GET_CAP: case AV_GET_ALL_CAP:
        [self send:sig type:MSG_ACCEPT label:lbl payload:kSinkCaps len:sizeof kSinkCaps];
        break;
    case AV_START:
        [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        self.state = SinkStateStreaming;
        break;
    case AV_SUSPEND:
        [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        [self.player flush];
        if (_opened && _mediaFD >= 0) self.state = SinkStateReady;
        break;
    case AV_CLOSE: case AV_ABORT:
        [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        [self endWithReason:@"Device closed the audio stream"];
        break;
    default: {
        if (sig == AV_DELAY_REPORT || sig == AV_SET_CONF || sig == AV_OPEN || sig == AV_RECONF) {
            [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        } else {
            uint8_t err = 0x19;   // NOT_SUPPORTED_COMMAND
            [self send:sig type:MSG_REJECT label:lbl payload:&err len:1];
        }
    }
    }
}

#pragma mark - media transport

- (void)openTransport {
    static int counter;
    _sockPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"bab-%d-%d.sock", getpid(), ++counter]];
    unlink(_sockPath.fileSystemRepresentation);
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strlcpy(a.sun_path, _sockPath.fileSystemRepresentation, sizeof a.sun_path);
    if (bind(lfd, (struct sockaddr *)&a, sizeof a) || listen(lfd, 1)) {
        close(lfd);
        [self endWithReason:@"Could not create helper socket"];
        return;
    }
    char exe[PATH_MAX];
    uint32_t sz = sizeof exe;
    _NSGetExecutablePath(exe, &sz);
    const char *argv[] = {exe, "--transport", self.address.UTF8String, _sockPath.UTF8String, NULL};
    pid_t pid = 0;
    if (posix_spawn(&pid, exe, NULL, NULL, (char *const *)argv, environ) != 0) {
        close(lfd);
        [self endWithReason:@"Could not start transport helper"];
        return;
    }
    _helperPID = pid;
    __weak SinkSession *ws = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        struct timeval tv = {15, 0};
        setsockopt(lfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        int c = accept(lfd, NULL, NULL);
        int fd = -1;
        if (c >= 0) {
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            char dummy, ctrl[CMSG_SPACE(sizeof(int))];
            struct iovec iov = {&dummy, 1};
            struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl, .msg_controllen = sizeof ctrl};
            if (recvmsg(c, &m, 0) > 0) {
                struct cmsghdr *h = CMSG_FIRSTHDR(&m);
                if (h && h->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(h), sizeof fd);
            }
            close(c);
        }
        close(lfd);
        dispatch_async(dispatch_get_main_queue(), ^{ [ws transportReady:fd]; });
    });
}

- (void)transportReady:(int)fd {
    if (_ending) { if (fd >= 0) close(fd); return; }
    if (fd < 0) { [self endWithReason:@"Audio channel failed to open"]; return; }
    _mediaFD = fd;
    [_connectTimeout invalidate]; _connectTimeout = nil;
    _activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep |
                                                                     NSActivityLatencyCritical
                                                             reason:@"Receiving Bluetooth audio"];
    self.state = SinkStateReady;
    BABLog(@"Audio channel open; ready for audio");
    NSUUID *peerID = [(id)_peer respondsToSelector:@selector(identifier)] ? [(CBPeer *)_peer identifier] : nil;
    [BABLinkPriority.shared enableForPeer:peerID];
    _tick =[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_tick forMode:NSRunLoopCommonModes];
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(mediaLoop) object:nil];
    t.qualityOfService = NSQualityOfServiceUserInteractive;
    t.name = @"bab.media";
    [t start];
}

- (void)mediaLoop {
    static const size_t kBuf = 65536;
    uint8_t *buf = malloc(kBuf);
    size_t have = 0;
    int lastSeq = -1;
    int fd = _mediaFD;
    for (;;) {
        ssize_t n = recv(fd, buf + have, kBuf - have, 0);
        if (n <= 0) break;
        _mediaBytes += (uint64_t)n;
        have += (size_t)n;
        // A read can hold several RTP packets or part of one; packet boundaries come from the LATM element.
        size_t pos = 0;
        while (have - pos >= 13) {
            const uint8_t *b = buf + pos;
            if ((b[0] >> 6) != 2) { pos++; continue; }               // not RTP v2: resync
            size_t off = 12 + 4 * (b[0] & 0x0F);
            if (have - pos <= off) break;
            size_t used = 0;
            int r = _codec == kCodecSBC ? sbcPayloadLength(b + off, have - pos - off, &used)
                                        : latm_parse(&_latm, b + off, have - pos - off, NULL, NULL, &used);
            if (r == -2) break;                                      // incomplete
            if (r < 0) { pos++; continue; }                          // garbage: resync
            uint16_t seq = (uint16_t)(b[2] << 8 | b[3]);
            if (lastSeq >= 0 && seq != (uint16_t)(lastSeq + 1)) self.lostPackets += (uint16_t)(seq - lastSeq - 1);
            lastSeq = seq;
            _mediaPackets++;
            if (_codec == kCodecSBC) [self playSBC:b + off len:used];
            else [self playLATM:b + off len:used];
            pos += off + used;
        }
        memmove(buf, buf + pos, have - pos);
        have -= pos;
        if (have == kBuf) have = 0;
    }
    free(buf);
    close(fd);
    [self.player stop];
    self.player = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_ending) [self endWithReason:@"Audio channel closed"];
    });
}

// The player for the current stream, (re)created on the first frame or after an output change.
- (AACPlayer *)playerWithRate:(int)rate channels:(int)channels asc:(const uint8_t *)asc {
    AACPlayer *player = self.player;
    if (_playerNeedsRestart && player) { [player stop]; player = nil; self.player = nil; }
    if (!player) {
        _playerNeedsRestart = NO;
        player = [[AACPlayer alloc] initWithSampleRate:rate channels:channels asc:asc
                                             deviceUID:self.outputDeviceUID playback:YES];
        if (!player) return nil;
        player.volume = self.volume;
        self.player = player;
        BABLog(@"Playing %@ %d Hz %d ch on %@", asc ? @"AAC" : @"SBC", rate, channels, self.outputDeviceUID ?: @"default output");
    }
    if (self.state == SinkStateReady)   // audio without a START we parsed (e.g. merged signaling message)
        dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_ending) self.state = SinkStateStreaming; });
    return player;
}

- (void)playLATM:(const uint8_t *)p len:(size_t)n {
    FrameBatch batch;
    batch.count = 0;
    if (latm_parse(&_latm, p, n, collectFrame, &batch, NULL) < 0) return;
    AACPlayer *player = [self playerWithRate:_latm.sampleRate channels:_latm.channels asc:_latm.asc];
    for (int i = 0; i < batch.count; i++) [player decodeFrame:batch.buf[i] length:batch.len[i]];
}

- (void)playSBC:(const uint8_t *)p len:(size_t)n {
    AACPlayer *player = [self playerWithRate:_sampleRate channels:2 asc:NULL];
    if (!player) return;
    const OI_BYTE *data = p + 1;   // skip the media payload header
    uint32_t bytes = (uint32_t)(n - 1);
    int16_t pcm[SBC_MAX_BLOCKS * SBC_MAX_BANDS * 2];
    float out[SBC_MAX_BLOCKS * SBC_MAX_BANDS * 2];
    while (bytes > 0) {
        uint32_t outBytes = sizeof pcm;
        OI_STATUS st = OI_CODEC_SBC_DecodeFrame(&_sbcContext, &data, &bytes, pcm, &outBytes);
        if (st != OI_OK) { BABLog(@"SBC decode error %d", (int)st); break; }
        int ch = _sbcContext.common.frameInfo.nrof_channels;
        size_t frames = outBytes / sizeof(int16_t) / (size_t)ch;
        for (size_t i = 0; i < frames; i++) {
            float l = pcm[i * ch] / 32768.0f;
            out[2 * i] = l;
            out[2 * i + 1] = ch == 2 ? pcm[i * ch + 1] / 32768.0f : l;
        }
        [player pushPCM:out frames:frames];
    }
}

- (void)tick {
    uint64_t bytes = _mediaBytes;
    self.bitrateKbps = (bytes - _lastBytes) * 8 / 1000.0;
    _lastBytes = bytes;
    AACPlayer *p = self.player;
    if (p) {
        self.delayMs = p.estimatedOutputDelayMs;
        self.underruns = p.underruns;
    }
    // Diagnostics: `defaults write local.bluetooth-audio-bridge perSecondStats -bool YES` logs the
    // received rate every second (for correlating radio stalls with system events).
    double now = CFAbsoluteTimeGetCurrent();
    if (self.state == SinkStateStreaming && _lastTickTime > 0 &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"perSecondStats"])
        BABLog(@"s1: %.0f kbit/s, buffer %.0f ms, underruns %llu, lost %llu",
               self.bitrateKbps / (now - _lastTickTime), p.bufferedMs, self.underruns, self.lostPackets);
    _lastTickTime = now;
    if (++_ticks % 5 == 0) {
        // Diagnostics: `defaults write local.bluetooth-audio-bridge delayReportMs -int N` reports a fixed delay.
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL fixed = [defaults objectForKey:@"delayReportMs"] != nil;
        double wanted = fixed ? [defaults doubleForKey:@"delayReportMs"] : self.delayMs;
        if (p && self.state == SinkStateStreaming && fabs(wanted - _reportedDelayMs) >= (fixed ? 1 : 25))
            [self sendDelayReport:wanted];
        if (self.state == SinkStateStreaming)
            BABLog(@"stats: %.0f kbit/s, delay %.0f ms, buffer %.0f/%.0f ms, rate %.4f, underruns %llu, catch-ups %llu, lost %llu, level %.3f",
                   self.bitrateKbps, self.delayMs, p.bufferedMs, p.targetLatencyMs, p.playbackRatio, self.underruns,
                   p.catchUps, self.lostPackets, p.rmsSinceLastQuery);
    }
}

#pragma mark - transport helper process

+ (int)runTransportHelperWithAddress:(NSString *)address socketPath:(NSString *)path {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:address];
    __block CBL2CAPChannel *keep = nil;
    __block BOOL shipped = NO;
    // Hands the channel's socket (or -1 on failure) to the parent over the unix socket.
    void (^ship)(int) = ^(int fd) {
        int c = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        strlcpy(a.sun_path, path.fileSystemRepresentation, sizeof a.sun_path);
        if (connect(c, (struct sockaddr *)&a, sizeof a) != 0) exit(3);
        char dummy = fd >= 0 ? 'F' : 'X';
        struct iovec iov = {&dummy, 1};
        char ctrl[CMSG_SPACE(sizeof(int))] = {0};
        struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1};
        if (fd >= 0) {
            m.msg_control = ctrl;
            m.msg_controllen = sizeof ctrl;
            struct cmsghdr *h = CMSG_FIRSTHDR(&m);
            h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN(sizeof(int));
            memcpy(CMSG_DATA(h), &fd, sizeof fd);
        }
        sendmsg(c, &m, 0);
        close(c);
    };
    void (^onOpen)(CBL2CAPChannel *, long) = ^(CBL2CAPChannel *ch, long code) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (shipped) return;
            if (!ch) { BABLog(@"[helper] open failed (code %ld), will retry", code); return; }
            shipped = YES;
            keep = ch;
            ship([[ch valueForKey:@"socketFD"] intValue]);
        });
    };

    // This process's Bluetooth client takes a moment to reach the powered-on state, and an open
    // request sent before that is silently dropped by CoreBluetooth ("API MISUSE"). There's no
    // public way to observe that state on the classic peer, so wait briefly and keep retrying
    // until the channel opens. The source gives up on the stream after about 10 s.
    id<BABClassicPeer> peer = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.5];
    NSDate *nextAttempt = [NSDate dateWithTimeIntervalSinceNow:0.3];
    int attempts = 0;
    while (!shipped && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (shipped || nextAttempt.timeIntervalSinceNow > 0) continue;
        peer = [d classicPeer];
        if (!peer) { nextAttempt = [NSDate dateWithTimeIntervalSinceNow:0.25]; continue; }
        [peer setConnectL2CAPCallback:onOpen];
        [peer openL2CAPChannel:kPSM_AVDTP];
        if (++attempts > 1) BABLog(@"[helper] retrying audio channel (attempt %d)", attempts);
        nextAttempt = [NSDate dateWithTimeIntervalSinceNow:1.5];
    }
    if (!shipped) {
        BABLog(@"[helper] gave up after %d attempts", attempts);
        ship(-1);
        return 4;
    }
    // Keep the channel alive until the parent goes away (it SIGTERMs us when the session ends).
    while (getppid() != 1) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    (void)keep;
    return 0;
}

@end
