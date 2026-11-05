// AVDTP sink, acting as the *initiator*: the Mac opens the AVDTP signaling channel to an already
// paired A2DP source (the Fire TV), configures SBC, opens the media transport channel and
// records the incoming RTP/SBC stream.
//
//   Probe.app --args --sink <addr> [seconds]       (main role)
//   Probe.app --args --transport <addr> <sockpath> (internal helper role, spawned by the main role)
//
// Opening L2CAP channels from user space uses private CoreBluetooth API (CBClassicPeer), because
// the public IOBluetoothL2CAPChannel path is non-functional on recent macOS. bluetoothd allows only
// one channel per PSM per client session, so the media transport channel (also PSM 0x19) is
// opened by a second process that hands the socket back over a unix socket (SCM_RIGHTS).
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <signal.h>
#include <mach-o/dyld.h>
#import "aacplayer.h"
#include "latm.h"

extern char **environ;
void probeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#define L(...) probeLog(__VA_ARGS__)

@interface IOBluetoothDevice (BABPrivate)
- (id)classicPeer;
@end
// Shape of the private CBClassicPeer methods we call.
@protocol BABClassicPeer
- (void)setConnectL2CAPCallback:(void (^)(CBL2CAPChannel *ch, long code))cb;
- (id)openL2CAPChannel:(unsigned long)psm;
- (void)sendMsg:(int)msg args:(NSDictionary *)args;   // CBPeer -> bluetoothd XPC
@end

static const unsigned long kPSM_AVDTP = 0x19;
enum { AV_DISCOVER = 1, AV_GET_CAP = 2, AV_SET_CONF = 3, AV_GET_CONF = 4, AV_RECONF = 5, AV_OPEN = 6,
       AV_START = 7, AV_CLOSE = 8, AV_SUSPEND = 9, AV_ABORT = 10, AV_SECURITY = 11,
       AV_GET_ALL_CAP = 12, AV_DELAY_REPORT = 13 };
enum { MSG_CMD = 0, MSG_GEN_REJECT = 1, MSG_ACCEPT = 2, MSG_REJECT = 3 };
static const uint8_t kLocalSEID = 1;
static BOOL gCapsOnly = NO;
static uint8_t gWantCodec = 0x02;
static NSString *gDeviceUID = nil;     // output device UID (nil = default output)   // 0x02 = MPEG-2/4 AAC (default), 0x00 = SBC   // --caps: list every remote endpoint's codec, configure nothing

static NSString *hexs(const uint8_t *b, size_t n) {
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n && i < 48; i++) [s appendFormat:@"%02x ", b[i]];
    if (n > 48) [s appendString:@"…"];
    return s;
}
static NSString *sigName(int s) {
    static NSString *n[] = {@"?", @"DISCOVER", @"GET_CAP", @"SET_CONF", @"GET_CONF", @"RECONF", @"OPEN",
                            @"START", @"CLOSE", @"SUSPEND", @"ABORT", @"SECURITY", @"GET_ALL_CAP", @"DELAY_REPORT"};
    return (s >= 1 && s <= 13) ? n[s] : [NSString stringWithFormat:@"sig%d", s];
}

// Our sink endpoint's capabilities: media transport + SBC (everything allowed, bitpool 2..53).
static const uint8_t kSinkCaps[] = {0x01, 0x00, 0x07, 0x06, 0x00, 0x00, 0xFF, 0xFF, 0x02, 0x35};

#pragma mark - transport helper role

static int transportMain(NSString *addr, NSString *sockPath) {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:addr];
    id<BABClassicPeer> peer = [d classicPeer];
    __block CBL2CAPChannel *keep = nil;
    [peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        int fd = ch ? [[ch valueForKey:@"socketFD"] intValue] : -1;
        L(@"[transport] channel callback ch=%@ code=%ld fd=%d", ch ? @"yes" : @"nil", code, fd);
        keep = ch;
        int c = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        strlcpy(a.sun_path, sockPath.fileSystemRepresentation, sizeof a.sun_path);
        if (connect(c, (struct sockaddr *)&a, sizeof a) != 0) { perror("[transport] connect"); exit(3); }
        char dummy = fd >= 0 ? 'F' : 'X';
        struct iovec iov = {&dummy, 1};
        char ctrl[CMSG_SPACE(sizeof(int))] = {0};
        struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1};
        if (fd >= 0) {
            m.msg_control = ctrl; m.msg_controllen = sizeof ctrl;
            struct cmsghdr *h = CMSG_FIRSTHDR(&m);
            h->cmsg_level = SOL_SOCKET; h->cmsg_type = SCM_RIGHTS; h->cmsg_len = CMSG_LEN(sizeof(int));
            memcpy(CMSG_DATA(h), &fd, sizeof fd);
        }
        sendmsg(c, &m, 0);
        close(c);
        if (fd < 0) exit(4);
    }];
    const char *mtuEnv = getenv("BAB_INMTU");
    if (mtuEnv && atoi(mtuEnv) > 0) {
        // Same XPC message (29) CBClassicPeer -openL2CAPChannel: sends, but with an incoming MTU option.
        int mtu = atoi(mtuEnv);
        [(id)peer sendMsg:29 args:@{@"kCBMsgArgPSM": @(kPSM_AVDTP),
                                    @"kCBMsgArgOptions": @{@"kCBL2CAPChannelInMTU": @(mtu), @"kCBL2CAPChannelMaxIncomingPayloadSize": @(mtu), @"kCBL2CAPChannelInMPS": @(mtu)}}];
        L(@"[transport] opening media channel with inMTU=%d...", mtu);
    } else {
        [peer openL2CAPChannel:kPSM_AVDTP];
        L(@"[transport] opening media channel...");
    }
    // Stay alive while the parent uses the socket; the parent kills us on exit.
    while (getppid() != 1) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    (void)keep;
    return 0;
}

#pragma mark - sink (main role)

@interface Sink : NSObject <NSStreamDelegate>
@property(strong) IOBluetoothDevice *dev;
@property(strong) id<BABClassicPeer> peer;
@property(strong) CBL2CAPChannel *sigCh;
@property(strong) NSInputStream *in;
@property(strong) NSOutputStream *out;
@property uint8_t label;
@property uint8_t remoteSEID;
@property BOOL configured, opened, streaming, weAreInitiator;
@property(strong) NSMutableArray<NSNumber *> *srcSEIDs;
@property pid_t helperPID;
@property int mediaFD;
@property(strong) NSString *sockPath;
@property(strong) NSFileHandle *sbcOut;
@property uint64_t mediaPackets, mediaBytes, lostPackets, resyncBytes;
@property(strong) NSDate *started;
@property(strong) AACPlayer *player;
@property double reportedDelayMs;
@property BOOL openSent;
@end

typedef struct { uint8_t buf[4][4096]; size_t len[4]; int count; } FrameBatch;
static void collectFrame(const uint8_t *f, size_t n, void *ctx) {
    FrameBatch *b = ctx;
    if (b->count < 4 && n <= sizeof b->buf[0]) { memcpy(b->buf[b->count], f, n); b->len[b->count++] = n; }
}

@implementation Sink {
    LatmState _latm;
    uint64_t _latmErrors;
}

- (void)send:(uint8_t)sig type:(uint8_t)type label:(uint8_t)lbl payload:(const uint8_t *)p len:(size_t)n {
    uint8_t b[128];
    b[0] = (uint8_t)(lbl << 4) | type;
    b[1] = sig;
    if (n) memcpy(b + 2, p, n);
    [self.out write:b maxLength:n + 2];
    L(@"TX %@ %@ label=%d: %@", sigName(sig), type == MSG_CMD ? @"cmd" : type == MSG_ACCEPT ? @"accept" : @"reject",
      lbl, hexs(b, n + 2));
}
- (void)cmd:(uint8_t)sig payload:(const uint8_t *)p len:(size_t)n {
    self.label = (self.label + 1) & 0x0F;
    [self send:sig type:MSG_CMD label:self.label payload:p len:n];
}

- (void)startWith:(NSString *)addr {
    self.dev = [IOBluetoothDevice deviceWithAddressString:addr];
    L(@"Device %@ '%@' paired=%d connected=%d", self.dev.addressString, self.dev.name, self.dev.isPaired, self.dev.isConnected);
    self.peer = [self.dev classicPeer];
    if (!self.peer) { L(@"No classicPeer for device (not known to bluetoothd?)"); exit(2); }
    __weak Sink *ws = self;
    [self.peer setConnectL2CAPCallback:^(CBL2CAPChannel *ch, long code) {
        dispatch_async(dispatch_get_main_queue(), ^{ [ws signalingOpened:ch code:code]; });
    }];
    [self.peer openL2CAPChannel:kPSM_AVDTP];
    L(@"Opening AVDTP signaling channel (PSM 0x19)...");
}

- (void)signalingOpened:(CBL2CAPChannel *)ch code:(long)code {
    if (!ch) { L(@"Signaling channel FAILED, code=%ld", code); exit(2); }
    self.sigCh = ch;
    self.in = ch.inputStream; self.out = ch.outputStream;
    self.in.delegate = self; self.out.delegate = self;
    [self.in scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [self.out scheduleInRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
    [self.in open]; [self.out open];
    L(@">>> Signaling channel OPEN (code=%ld, outMTU=%@)", code, [ch valueForKey:@"outgoingMTU"]);
    self.weAreInitiator = YES;
    [self cmd:AV_DISCOVER payload:NULL len:0];
}

- (void)stream:(NSStream *)s handleEvent:(NSStreamEvent)e {
    if (s == self.in && (e & NSStreamEventHasBytesAvailable)) {
        uint8_t b[1024];
        NSInteger n = [self.in read:b maxLength:sizeof b];
        if (n >= 2) [self handle:b len:(size_t)n];
    }
    if (e & (NSStreamEventErrorOccurred | NSStreamEventEndEncountered)) {
        L(@"Signaling channel %@: %@", s == self.in ? @"in" : @"out",
          (e & NSStreamEventErrorOccurred) ? s.streamError : @"closed by remote");
        [self finish];
    }
}

- (void)handle:(const uint8_t *)b len:(size_t)n {
    uint8_t lbl = b[0] >> 4, pkt = (b[0] >> 2) & 3, type = b[0] & 3, sig = b[1] & 0x3F;
    L(@"RX %@ %@ label=%d: %@", sigName(sig),
      type == MSG_CMD ? @"cmd" : type == MSG_ACCEPT ? @"accept" : type == MSG_REJECT ? @"REJECT" : @"GEN-REJECT", lbl, hexs(b, n));
    if (pkt != 0) { L(@"(fragmented AVDTP packet type %d not handled)", pkt); return; }
    const uint8_t *p = b + 2; size_t pl = n - 2;
    if (type == MSG_CMD) { [self remoteCommand:sig label:lbl payload:p len:pl]; return; }
    if (type != MSG_ACCEPT) {
        L(@"!!! %@ rejected (error 0x%02x)", sigName(sig), pl ? p[pl - 1] : 0);
        if (sig == AV_DELAY_REPORT && self.configured && !self.openSent) [self sendOpen];
        return;
    }

    switch (sig) {
    case AV_DISCOVER: {
        L(@"(remote seid %d)", self.remoteSEID);
        self.srcSEIDs = [NSMutableArray array];
        for (size_t i = 0; i + 1 < pl; i += 2) {
            uint8_t seid = p[i] >> 2, inUse = (p[i] >> 1) & 1, media = p[i + 1] >> 4, tsep = (p[i + 1] >> 3) & 1;
            L(@"  SEP seid=%d inUse=%d media=%@ role=%@", seid, inUse, media == 0 ? @"audio" : @(media), tsep ? @"SINK" : @"SOURCE");
            if (media == 0 && tsep == 0 && !inUse) [self.srcSEIDs addObject:@(seid)];
        }
        [self nextCapabilityQuery];
        break;
    }
    case AV_GET_CAP: case AV_GET_ALL_CAP: {
        // Walk the service capabilities, looking for the codec we want.
        BOOL match = NO;
        for (size_t i = 0; i + 1 < pl;) {
            uint8_t cat = p[i], len = p[i + 1];
            if (cat == 7 && len >= 2) {
                uint8_t codec = p[i + 3];
                L(@"  codec cap: type=0x%02x info=%@", codec, hexs(p + i + 4, len - 2));
                if (codec == gWantCodec) match = YES;
                if (codec == 0xFF && len >= 8) {
                    const uint8_t *v = p + i + 4;
                    L(@"    vendor codec: vendorID=0x%08x codecID=0x%04x", v[0] | v[1] << 8 | v[2] << 16 | (uint32_t)v[3] << 24, v[4] | v[5] << 8);
                }
            } else L(@"  service cap cat=%d len=%d", cat, len);
            i += 2 + len;
        }
        if (gCapsOnly) {
            if (self.srcSEIDs.count) [self nextCapabilityQuery]; else [self finish];
            break;
        }
        if (match && !self.configured && gWantCodec == 0x00) {
            uint8_t conf[] = {(uint8_t)(self.remoteSEID << 2), (uint8_t)(kLocalSEID << 2),
                              0x01, 0x00,                                   // media transport
                              0x07, 0x06, 0x00, 0x00,                       // audio, SBC
                              0x21, 0x15, 0x02, 0x35};                      // 44.1k joint, 16 blk, 8 sb, loudness, bp 2..53
            [self cmd:AV_SET_CONF payload:conf len:sizeof conf];
        } else if (match && !self.configured && gWantCodec == 0x02) {
            uint8_t conf[] = {(uint8_t)(self.remoteSEID << 2), (uint8_t)(kLocalSEID << 2),
                              0x01, 0x00,                                   // media transport
                              0x07, 0x08, 0x00, 0x02,                       // audio, MPEG-2/4 AAC
                              0x80,                                         // object type: MPEG-2 AAC LC
                              0x01, 0x04,                                   // 44.1 kHz, 2 channels
                              0x04, 0xE2, 0x00,                             // CBR, 320000 bit/s
                              0x08, 0x00};                                  // delay reporting
            [self cmd:AV_SET_CONF payload:conf len:sizeof conf];
        } else if (!self.configured) {
            [self nextCapabilityQuery];
        }
        break;
    }
    case AV_SET_CONF: {
        self.configured = YES;
        if (gWantCodec == 0x02) {
            [self sendDelayReport:200.0];   // initial estimate; OPEN follows its response
        } else {
            [self sendOpen];
        }
        break;
    }
    case AV_DELAY_REPORT:
        if (!self.opened && !self.openSent) [self sendOpen];
        break;
    case AV_OPEN:
        self.opened = YES;
        L(@">>> Stream OPEN accepted. Opening media transport channel via helper process...");
        [self openTransport];
        break;
    case AV_START:
        self.streaming = YES;
        L(@">>> STREAMING (we sent START)");
        break;
    default: break;
    }
}

- (void)nextCapabilityQuery {
    if (self.srcSEIDs.count == 0) { L(@"No (more) free audio SOURCE endpoints with SBC on the remote"); return; }
    self.remoteSEID = self.srcSEIDs.firstObject.unsignedCharValue;
    [self.srcSEIDs removeObjectAtIndex:0];
    uint8_t s = (uint8_t)(self.remoteSEID << 2);
    [self cmd:AV_GET_ALL_CAP payload:&s len:1];   // AVDTP 1.3: also reports delay-reporting support
}

// Commands the Fire TV sends to us (as acceptor of those).
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
        self.streaming = YES;
        L(@">>> Fire TV sent START: audio should flow now");
        break;
    case AV_SUSPEND:
        [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        self.streaming = NO;
        [self.player flush];
        L(@">>> Fire TV SUSPENDED the stream (no audio playing)");
        break;
    case AV_CLOSE: case AV_ABORT:
        [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        L(@">>> Fire TV closed/aborted the stream");
        break;
    case AV_DELAY_REPORT: case AV_SET_CONF: case AV_OPEN: case AV_RECONF:
        [self send:sig type:MSG_ACCEPT label:lbl payload:NULL len:0];
        break;
    default: {
        uint8_t err = 0x19; // NOT_SUPPORTED_COMMAND
        [self send:sig type:MSG_REJECT label:lbl payload:&err len:1];
    }
    }
}

#pragma mark media transport

- (void)openTransport {
    self.sockPath = [NSString stringWithFormat:@"/tmp/bab-%d.sock", getpid()];
    unlink(self.sockPath.fileSystemRepresentation);
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strlcpy(a.sun_path, self.sockPath.fileSystemRepresentation, sizeof a.sun_path);
    if (bind(lfd, (struct sockaddr *)&a, sizeof a) || listen(lfd, 1)) { perror("bind"); return; }

    char exe[PATH_MAX]; uint32_t sz = sizeof exe;
    _NSGetExecutablePath(exe, &sz);
    const char *argv[] = {exe, "--transport", self.dev.addressString.UTF8String, self.sockPath.UTF8String, NULL};
    pid_t pid;
    int r = posix_spawn(&pid, exe, NULL, NULL, (char *const *)argv, environ);
    self.helperPID = r == 0 ? pid : 0;
    L(@"Spawned transport helper pid=%d (r=%d)", pid, r);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int c = accept(lfd, NULL, NULL);
        char dummy; char ctrl[CMSG_SPACE(sizeof(int))];
        struct iovec iov = {&dummy, 1};
        struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl, .msg_controllen = sizeof ctrl};
        int fd = -1;
        if (recvmsg(c, &m, 0) > 0) {
            struct cmsghdr *h = CMSG_FIRSTHDR(&m);
            if (h && h->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(h), sizeof fd);
        }
        close(c); close(lfd);
        dispatch_async(dispatch_get_main_queue(), ^{ [self transportReady:fd]; });
    });
}

- (void)transportReady:(int)fd {
    if (fd < 0) { L(@"!!! Media transport channel FAILED to open"); return; }
    self.mediaFD = fd;
    L(@">>> Media transport channel OPEN (fd=%d). Waiting for the Fire TV to START streaming...", fd);
    // Apps launched via `open` run with cwd "/", so write next to the .app bundle instead.
    NSString *path = [[NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:gWantCodec == 0x02 ? @"capture.aac.pkts" : @"capture.sbc.pkts"];
    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    self.sbcOut = [NSFileHandle fileHandleForWritingAtPath:path];
    L(@"Raw SBC frames will be written to %@", path);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ [self mediaLoop]; });
}

- (void)mediaLoop {
    int type = 0; socklen_t tl = sizeof type;
    getsockopt(self.mediaFD, SOL_SOCKET, SO_TYPE, &type, &tl);
    L(@"media socket type=%d (%@)", type, type == SOCK_STREAM ? @"stream: packets can arrive merged" : @"packet");
    static uint8_t buf[65536];
    size_t have = 0;
    int lastSeq = -1;
    for (;;) {
        ssize_t n = recv(self.mediaFD, buf + have, sizeof buf - have, 0);
        if (n <= 0) { L(@"Media channel closed (%zd)", n); return; }
        if (self.mediaPackets == 0) self.started = [NSDate date];
        self.mediaBytes += (uint64_t)n;
        have += (size_t)n;
        // A read may hold several RTP packets (or part of one). RTP has no length field, so the
        // packet boundary is found by parsing the LATM element (SBC: one packet per read assumed).
        size_t pos = 0;
        while (have - pos >= 13) {
            const uint8_t *b = buf + pos;
            if ((b[0] >> 6) != 2) { pos++; self.resyncBytes++; continue; }   // not an RTP v2 header: resync
            size_t off = 12 + 4 * (b[0] & 0x0F);
            if (have - pos <= off) break;
            size_t pktLen;
            if (gWantCodec == 0x02) {
                size_t used = 0;
                int r = latm_parse(&_latm, b + off, have - pos - off, NULL, NULL, &used);
                if (r == -2) break;                                   // incomplete: wait for more bytes
                if (r < 0) { pos++; self.resyncBytes++; continue; }  // garbage: resync
                pktLen = off + used;
            } else {
                pktLen = have - pos;
            }
            [self handleRTP:b len:pktLen payloadOffset:off lastSeq:&lastSeq];
            pos += pktLen;
        }
        memmove(buf, buf + pos, have - pos);
        have -= pos;
        if (have == sizeof buf) have = 0;  // should never happen; avoid a stuck buffer
    }
}

- (void)handleRTP:(const uint8_t *)b len:(size_t)n payloadOffset:(size_t)off lastSeq:(int *)lastSeq {
    self.mediaPackets++;
    uint16_t seq = (uint16_t)(b[2] << 8 | b[3]);
    if (*lastSeq >= 0 && seq != (uint16_t)(*lastSeq + 1)) {
        self.lostPackets += (uint16_t)(seq - *lastSeq - 1);
        L(@"RTP gap: seq %d -> %u", *lastSeq, seq);
    }
    *lastSeq = seq;
    if (gWantCodec == 0x00) off += 1;  // SBC media payload header (frame count); AAC has none
    if (n <= off) return;
    if (self.mediaPackets <= 2) {
        uint32_t ts = (uint32_t)b[4] << 24 | b[5] << 16 | b[6] << 8 | b[7];
        L(@"media pkt #%llu len=%zu seq=%u ts=%u pt=%d payload=%@", self.mediaPackets, n, seq, ts, b[1] & 0x7F,
          hexs(b + off, 24));
    }
    uint16_t plen = (uint16_t)(n - off);
    uint8_t hdr[2] = {(uint8_t)(plen >> 8), (uint8_t)plen};
    NSMutableData *rec = [NSMutableData dataWithBytes:hdr length:2];
    [rec appendBytes:b + off length:plen];
    @synchronized(self) { [self.sbcOut writeData:rec]; }
    if (gWantCodec == 0x02) [self playAAC:b + off len:plen];
}

// LATM payload -> AAC access units -> decoder/output (created once the stream format is known).
- (void)playAAC:(const uint8_t *)p len:(size_t)n {
    FrameBatch batch;
    batch.count = 0;
    if (latm_parse(&_latm, p, n, collectFrame, &batch, NULL) < 0) {
        if (++_latmErrors <= 5) L(@"LATM parse error (packet %llu)", self.mediaPackets);
        return;
    }
    if (!self.player) {
        L(@"Stream format: AAC object type %d, %d Hz, %d ch", _latm.objectType, _latm.sampleRate, _latm.channels);
        self.player = [[AACPlayer alloc] initWithSampleRate:_latm.sampleRate channels:_latm.channels
                                                        asc:_latm.asc deviceUID:gDeviceUID playback:YES];
        if (!self.player) return;
    }
    for (int i = 0; i < batch.count; i++) [self.player decodeFrame:batch.buf[i] length:batch.len[i]];
}

- (void)sendOpen {
    self.openSent = YES;
    uint8_t s = (uint8_t)(self.remoteSEID << 2);
    [self cmd:AV_OPEN payload:&s len:1];
}

- (void)sendDelayReport:(double)ms {
    uint16_t d = (uint16_t)lround(ms * 10);   // unit: 1/10 ms
    uint8_t pl[] = {(uint8_t)(self.remoteSEID << 2), (uint8_t)(d >> 8), (uint8_t)d};
    [self cmd:AV_DELAY_REPORT payload:pl len:sizeof pl];
    self.reportedDelayMs = ms;
    L(@"Delay report sent: %.1f ms", ms);
}

- (void)statusTick {
    if (self.player && self.streaming) {
        double d = self.player.estimatedOutputDelayMs;
        if (fabs(d - self.reportedDelayMs) >= 25) [self sendDelayReport:d];
    }
    if (self.player)
        L(@"status: lost=%llu resync=%llu packets=%llu decoded=%llu errors=%llu buffer=%.0fms underruns=%llu dropped=%llu level=%.3f",
          self.lostPackets, self.resyncBytes, self.mediaPackets, self.player.framesDecoded, self.player.decodeErrors, self.player.bufferedMs,
          self.player.underruns, self.player.droppedSamples, self.player.rmsSinceLastQuery);
    if (self.player) L(@"        rate=%.4f target=%.0fms delay≈%.0fms", self.player.playbackRatio, self.player.targetLatencyMs,
                       self.player.estimatedOutputDelayMs);
}

- (void)finish {
    [self.player stop];
    if (self.helperPID) kill(self.helperPID, SIGTERM);
    if (self.sockPath) unlink(self.sockPath.fileSystemRepresentation);
    @synchronized(self) { [self.sbcOut closeFile]; }
    double secs = self.started ? -[self.started timeIntervalSinceNow] : 0;
    L(@"Summary: configured=%d opened=%d streaming=%d mediaPackets=%llu bytes=%llu over %.1fs (%.0f kbit/s)",
      self.configured, self.opened, self.streaming, self.mediaPackets, self.mediaBytes, secs,
      secs > 0 ? self.mediaBytes * 8 / secs / 1000 : 0);
    exit(0);
}
@end

static int devicesMain(void) {
    for (NSDictionary *d in [AACPlayer outputDevices]) L(@"output device: %@  uid=%@", d[@"name"], d[@"uid"]);
    return 0;
}

// Offline: decode a capture.aac.pkts file without playing it, report stats.
static int decodeTestMain(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    const uint8_t *p = data.bytes;
    size_t pos = 0, pkts = 0;
    LatmState st = {0};
    AACPlayer *player = nil;
    while (pos + 2 <= data.length) {
        size_t n = (size_t)p[pos] << 8 | p[pos + 1];
        FrameBatch batch; batch.count = 0;
        if (latm_parse(&st, p + pos + 2, n, collectFrame, &batch, NULL) < 0) L(@"LATM error at packet %zu", pkts);
        if (!player && st.haveConfig)
            player = [[AACPlayer alloc] initWithSampleRate:st.sampleRate channels:st.channels asc:st.asc deviceUID:nil playback:NO];
        for (int i = 0; i < batch.count; i++) [player decodeFrame:batch.buf[i] length:batch.len[i]];
        pos += 2 + n; pkts++;
    }
    L(@"decode-test: packets=%zu decoded=%llu errors=%llu level(rms)=%.4f", pkts, player.framesDecoded,
      player.decodeErrors, player.rmsSinceLastQuery);
    return 0;
}

int avdtpMain(int argc, const char *argv[]) {
    if (!strcmp(argv[1], "--devices")) return devicesMain();
    if (argc >= 3 && !strcmp(argv[1], "--decode-test")) return decodeTestMain(@(argv[2]));
    if (argc >= 4 && !strcmp(argv[1], "--transport")) return transportMain(@(argv[2]), @(argv[3]));
    if (!strcmp(argv[1], "--caps")) gCapsOnly = YES;
    if (argc >= 5 && !strcmp(argv[4], "sbc")) gWantCodec = 0x00;
    if (argc >= 6 && strcmp(argv[5], "-")) gDeviceUID = @(argv[5]);
    if (argc >= 7) setenv("BAB_INMTU", argv[6], 1);   // inherited by the transport helper
    if (argc < 3) { L(@"usage: --sink <addr> [seconds] [aac|sbc]"); return 1; }
    int seconds = argc >= 4 ? atoi(argv[3]) : 60;
    Sink *s = [Sink new];
    [s startWith:@(argv[2])];
    [NSTimer scheduledTimerWithTimeInterval:5 target:s selector:@selector(statusTick) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    [s finish];
    return 0;
}
