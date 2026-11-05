#import "SinkSession.h"
#import "AACPlayer.h"
#import "Log.h"
#include "latm.h"
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

static const unsigned long kPSM_AVDTP = 0x19;
enum { AV_DISCOVER = 1, AV_GET_CAP = 2, AV_SET_CONF = 3, AV_GET_CONF = 4, AV_RECONF = 5, AV_OPEN = 6,
       AV_START = 7, AV_CLOSE = 8, AV_SUSPEND = 9, AV_ABORT = 10, AV_SECURITY = 11,
       AV_GET_ALL_CAP = 12, AV_DELAY_REPORT = 13 };
enum { MSG_CMD = 0, MSG_GEN_REJECT = 1, MSG_ACCEPT = 2, MSG_REJECT = 3 };
static const uint8_t kLocalSEID = 1;
static const uint8_t kCodecAAC = 0x02;
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
    NSTimer *_tick, *_connectTimeout;
    int _ticks;
    double _reportedDelayMs;
    // media thread state
    LatmState _latm;
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
    self.player.volume = volume;
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

- (void)openSignaling {
    __weak SinkSession *ws = self;
    [_peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        dispatch_async(dispatch_get_main_queue(), ^{ [ws signalingOpened:ch code:code]; });
    }];
    [_peer openL2CAPChannel:kPSM_AVDTP];
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
    [_tick invalidate]; _tick = nil;
    [_connectTimeout invalidate]; _connectTimeout = nil;
    _in.delegate = nil; _out.delegate = nil;
    [_in close]; [_out close];
    _in = nil; _out = nil; _sigCh = nil;
    [_peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {}];
    if (_helperPID > 0) { kill(_helperPID, SIGTERM); waitpid(_helperPID, NULL, WNOHANG); _helperPID = 0; }
    if (_sockPath) unlink(_sockPath.fileSystemRepresentation);
    if (_mediaFD >= 0) shutdown(_mediaFD, SHUT_RDWR);   // media thread closes it and stops the player
    self.state = SinkStateEnded;
}

#pragma mark - signaling

- (void)signalingOpened:(CBL2CAPChannel *)ch code:(long)code {
    if (_ending) return;
    if (!ch) { [self endWithReason:[NSString stringWithFormat:@"Could not reach device (code %ld)", code]]; return; }
    _sigCh = ch;
    _in = ch.inputStream; _out = ch.outputStream;
    _in.delegate = self; _out.delegate = self;
    [_in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [_out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [_in open]; [_out open];
    BABLog(@"Signaling channel open");
    [self cmd:AV_DISCOVER payload:NULL len:0];
}

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (s == _in && (e & NSStreamEventHasBytesAvailable)) {
        uint8_t b[1024];
        NSInteger n = [_in read:b maxLength:sizeof b];
        if (n >= 2) [self handle:b len:(size_t)n];
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
        for (size_t i = 0; i + 1 < pl; i += 2 + p[i + 1])
            if (p[i] == 7 && p[i + 1] >= 2 && p[i + 3] == kCodecAAC) aac = YES;
        if (aac && !_configured) [self configureAAC];
        else if (!_configured) [self queryNextEndpoint];
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
    if (_pendingSEIDs.count == 0) { [self endWithReason:@"Device offers no AAC audio source"]; return; }
    _remoteSEID = _pendingSEIDs.firstObject.unsignedCharValue;
    [_pendingSEIDs removeObjectAtIndex:0];
    uint8_t s = (uint8_t)(_remoteSEID << 2);
    [self cmd:AV_GET_ALL_CAP payload:&s len:1];
}

- (void)configureAAC {
    uint8_t conf[] = {(uint8_t)(_remoteSEID << 2), (uint8_t)(kLocalSEID << 2),
                      0x01, 0x00,                 // media transport
                      0x07, 0x08, 0x00, 0x02,     // audio, MPEG-2/4 AAC
                      0x80,                       // MPEG-2 AAC LC
                      0x01, 0x04,                 // 44.1 kHz, stereo
                      0x04, 0xE2, 0x00,           // CBR, 320 kbit/s (the source caps it to the packet size)
                      0x08, 0x00};                // delay reporting
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
    self.codecDescription = @"AAC";
    self.state = SinkStateReady;
    BABLog(@"Audio channel open; ready for audio");
    _tick = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
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
            int r = latm_parse(&_latm, b + off, have - pos - off, NULL, NULL, &used);
            if (r == -2) break;                                      // incomplete
            if (r < 0) { pos++; continue; }                          // garbage: resync
            uint16_t seq = (uint16_t)(b[2] << 8 | b[3]);
            if (lastSeq >= 0 && seq != (uint16_t)(lastSeq + 1)) self.lostPackets += (uint16_t)(seq - lastSeq - 1);
            lastSeq = seq;
            _mediaPackets++;
            [self playLATM:b + off len:used];
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

- (void)playLATM:(const uint8_t *)p len:(size_t)n {
    FrameBatch batch;
    batch.count = 0;
    if (latm_parse(&_latm, p, n, collectFrame, &batch, NULL) < 0) return;
    AACPlayer *player = self.player;
    if (_playerNeedsRestart && player) { [player stop]; player = nil; self.player = nil; }
    if (!player) {
        _playerNeedsRestart = NO;
        player = [[AACPlayer alloc] initWithSampleRate:_latm.sampleRate channels:_latm.channels asc:_latm.asc
                                             deviceUID:self.outputDeviceUID playback:YES];
        if (!player) return;
        player.volume = self.volume;
        self.player = player;
        BABLog(@"Playing AAC %d Hz %d ch on %@", _latm.sampleRate, _latm.channels, self.outputDeviceUID ?: @"default output");
    }
    for (int i = 0; i < batch.count; i++) [player decodeFrame:batch.buf[i] length:batch.len[i]];
    if (self.state == SinkStateReady)   // audio without a START we parsed (e.g. merged signaling message)
        dispatch_async(dispatch_get_main_queue(), ^{ if (!self->_ending) self.state = SinkStateStreaming; });
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
    if (++_ticks % 5 == 0) {
        if (p && self.state == SinkStateStreaming && fabs(self.delayMs - _reportedDelayMs) >= 25)
            [self sendDelayReport:self.delayMs];
        if (self.state == SinkStateStreaming)
            BABLog(@"stats: %.0f kbit/s, delay %.0f ms, buffer %.0f ms, rate %.4f, underruns %llu, lost %llu",
                   self.bitrateKbps, self.delayMs, p.bufferedMs, p.playbackRatio, self.underruns, self.lostPackets);
    }
}

#pragma mark - transport helper process

+ (int)runTransportHelperWithAddress:(NSString *)address socketPath:(NSString *)path {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:address];
    id<BABClassicPeer> peer = [d classicPeer];
    __block CBL2CAPChannel *keep = nil;
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        int fd = ch ? [[ch valueForKey:@"socketFD"] intValue] : -1;
        keep = ch;
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
        if (fd < 0) exit(4);
    }];
    [peer openL2CAPChannel:kPSM_AVDTP];
    // Keep the channel alive until the parent goes away (it SIGTERMs us when the session ends).
    while (getppid() != 1) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    (void)keep;
    return 0;
}

@end
