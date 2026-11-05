// Feasibility probe: can a user-space app make this Mac look like a Bluetooth
// speaker (A2DP sink) and receive the incoming AVDTP (PSM 0x19) channel?
//
// Build:  ./build.sh      Run:  ./probe [seconds] [--no-cod]
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

static const BluetoothL2CAPPSM kAVDTP = 0x0019;
// Service classes: Rendering (bit 18) + Audio (bit 21); Major: Audio/Video; Minor: Loudspeaker
static const BluetoothClassOfDevice kSpeakerCoD = 0x240414;

static NSDictionary *u16(uint16_t v) {
    return @{@"DataElementType": @1, @"DataElementSize": @2, @"DataElementValue": @(v)};
}
void logf_(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void probeLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void logf_(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    printf("[%s] %s\n", [[NSDate.date description] UTF8String], s.UTF8String);
    fflush(stdout);
}

@interface Probe : NSObject <IOBluetoothL2CAPChannelDelegate>
@property NSMutableArray *keep;
@end

@implementation Probe
- (instancetype)init { if ((self = [super init])) _keep = [NSMutableArray array]; return self; }

- (void)deviceConnected:(IOBluetoothUserNotification *)n device:(IOBluetoothDevice *)d {
    logf_(@"ACL connect: %@ (%@) CoD=0x%06x incoming=%d", d.name, d.addressString,
          d.classOfDevice, d.isIncoming);
}
- (void)l2capOpened:(IOBluetoothUserNotification *)n channel:(IOBluetoothL2CAPChannel *)ch {
    logf_(@"L2CAP channel opened: PSM=0x%04x incoming=%d device=%@ (%@)", ch.PSM,
          ch.isIncoming, ch.device.name, ch.device.addressString);
    if (ch.PSM == kAVDTP && ch.isIncoming) {
        logf_(@">>> Incoming AVDTP channel reached user space. Claiming delegate.");
        IOReturn r = [ch setDelegate:self];
        logf_(@"setDelegate -> 0x%x", r);
        [self.keep addObject:ch];
    }
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)ch data:(void *)p length:(size_t)len {
    NSMutableString *hex = [NSMutableString string];
    for (size_t i = 0; i < MIN(len, (size_t)32); i++) [hex appendFormat:@"%02x ", ((uint8_t *)p)[i]];
    logf_(@"AVDTP data on PSM 0x%04x (%zu bytes): %@", ch.PSM, len, hex);
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)ch {
    logf_(@"L2CAP channel closed: PSM=0x%04x", ch.PSM);
}
@end

@interface Scanner : NSObject <IOBluetoothDeviceInquiryDelegate>
@property BOOL done;
@end
@implementation Scanner
- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)s device:(IOBluetoothDevice *)d {
    logf_(@"Found: %@  name='%@'  CoD=0x%06x  paired=%d", d.addressString, d.name, d.classOfDevice, d.isPaired);
}
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)s error:(IOReturn)e aborted:(BOOL)a {
    logf_(@"Inquiry complete err=0x%x aborted=%d", e, a);
    self.done = YES;
}
@end

static int scanMain(int seconds) {
    Scanner *sc = [Scanner new];
    IOBluetoothDeviceInquiry *q = [IOBluetoothDeviceInquiry inquiryWithDelegate:sc];
    q.inquiryLength = (uint8_t)MIN(seconds, 60);
    q.updateNewDeviceNames = YES;
    IOReturn r = [q start];
    logf_(@"Inquiry start -> 0x%x (%d s)", r, seconds);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds + 15];
    while (!sc.done && [end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    for (IOBluetoothDevice *d in q.foundDevices)
        logf_(@"Result: %@  name='%@'  CoD=0x%06x", d.addressString, d.name, d.classOfDevice);
    return 0;
}

@interface Pairer : NSObject
@property BOOL done;
@end
@implementation Pairer
- (void)devicePairingStarted:(id)s { logf_(@"Pairing started"); }
- (void)devicePairingConnecting:(id)s { logf_(@"Pairing: connecting"); }
- (void)devicePairingConnected:(id)s { logf_(@"Pairing: baseband connected"); }
- (void)devicePairingUserConfirmationRequest:(IOBluetoothDevicePair *)s numericValue:(BluetoothNumericValue)v {
    logf_(@"Pairing: confirm code %06u (auto-accepting on Mac; accept on the TV if it asks)", v);
    [s replyUserConfirmation:YES];
}
- (void)devicePairingUserPasskeyNotification:(id)s passkey:(BluetoothPasskey)p { logf_(@"Pairing: passkey %06u", p); }
- (void)devicePairingPINCodeRequest:(IOBluetoothDevicePair *)s {
    logf_(@"Pairing: PIN requested, replying 0000");
    BluetoothPINCode pin = {{'0', '0', '0', '0'}};
    [s replyPINCode:4 PINCode:&pin];
}
- (void)devicePairingFinished:(id)s error:(IOReturn)e { logf_(@"Pairing finished err=0x%x", e); self.done = YES; }
- (void)deviceSimplePairingComplete:(id)s status:(BluetoothHCIEventStatus)st { logf_(@"Simple pairing complete status=%u", st); }
@end

static int pairMain(NSString *addr) {
    IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:addr];
    logf_(@"Device %@ name='%@' paired=%d connected=%d", d.addressString, d.name, d.isPaired, d.isConnected);
    IOReturn oc = [d openConnection];
    logf_(@"openConnection -> 0x%x, connected=%d", oc, d.isConnected);
    Pairer *p = [Pairer new];
    IOBluetoothDevicePair *pr = [IOBluetoothDevicePair pairWithDevice:d];
    pr.delegate = p;
    IOReturn r = [pr start];
    logf_(@"Pair start -> 0x%x", r);
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:90];
    while (!p.done && [end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    logf_(@"After pairing: paired=%d connected=%d", d.isPaired, d.isConnected);
    IOReturn q = [d performSDPQuery:nil];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5]];
    logf_(@"SDP query -> 0x%x; remote services:", q);
    for (IOBluetoothSDPServiceRecord *rec in d.services) logf_(@"  service: %@", rec.getServiceName);
    return 0;
}

void probeLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    logf_(@"%@", s);
}
int avdtpMain(int argc, const char *argv[]);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 2 && (!strcmp(argv[1], "--sink") || !strcmp(argv[1], "--caps") || !strcmp(argv[1], "--devices") || !strcmp(argv[1], "--decode-test") || !strcmp(argv[1], "--transport"))) return avdtpMain(argc, argv);
        if (argc >= 3 && !strcmp(argv[1], "--connect")) {      // test aid: bring the baseband link up
            IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:@(argv[2])];
            NSDate *t0 = [NSDate date];
            IOReturn r = [d openConnection];
            logf_(@"openConnection -> 0x%x after %.1fs, connected=%d", r, -[t0 timeIntervalSinceNow], d.isConnected);
            return 0;
        }
        if (argc >= 3 && !strcmp(argv[1], "--disconnect")) {   // test aid: drop the baseband link
            IOBluetoothDevice *d = [IOBluetoothDevice deviceWithAddressString:@(argv[2])];
            logf_(@"closeConnection -> 0x%x", [d closeConnection]);
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            logf_(@"connected now: %d", d.isConnected);
            return 0;
        }
        if (argc >= 2 && !strcmp(argv[1], "--scan")) return scanMain(argc >= 3 ? atoi(argv[2]) : 15);
        if (argc >= 3 && !strcmp(argv[1], "--pair")) return pairMain(@(argv[2]));
        int seconds = 120;
        BOOL setCoD = YES;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--no-cod")) setCoD = NO;
            else seconds = atoi(argv[i]);
        }

        IOBluetoothHostController *hc = IOBluetoothHostController.defaultController;
        logf_(@"Controller %@ '%@' power=%d", hc.addressAsString, hc.nameAsString, hc.powerState);
        logf_(@"Current Class of Device: 0x%06x", hc.classOfDevice);

        // Private: raw HCI Read/Write_Class_Of_Device (the public setter is a no-op on recent macOS)
        SEL rdSel = NSSelectorFromString(@"BluetoothHCIReadClassOfDevice:");
        SEL wrSel = NSSelectorFromString(@"BluetoothHCIWriteClassOfDevice:");
        IOReturn (*rd)(id, SEL, BluetoothClassOfDevice *) = (void *)[hc methodForSelector:rdSel];
        IOReturn (*wr)(id, SEL, BluetoothClassOfDevice) = (void *)[hc methodForSelector:wrSel];
        if ([hc respondsToSelector:rdSel]) {
            BluetoothClassOfDevice cod = 0;
            IOReturn r = rd(hc, rdSel, &cod);
            logf_(@"HCI Read_Class_Of_Device -> 0x%x, CoD=0x%06x", r, cod);
        }

        if (setCoD) {
            IOReturn r = [hc setClassOfDevice:kSpeakerCoD forTimeInterval:120];
            logf_(@"setClassOfDevice(0x%06x, 120s) -> 0x%x", kSpeakerCoD, r);
            if ([hc respondsToSelector:wrSel]) {
                r = wr(hc, wrSel, kSpeakerCoD);
                logf_(@"HCI Write_Class_Of_Device(0x%06x) -> 0x%x", kSpeakerCoD, r);
            }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
            logf_(@"Class of Device now (cached getter): 0x%06x", hc.classOfDevice);
            if ([hc respondsToSelector:rdSel]) {
                BluetoothClassOfDevice cod = 0;
                IOReturn r2 = rd(hc, rdSel, &cod);
                logf_(@"HCI Read_Class_Of_Device after write -> 0x%x, CoD=0x%06x", r2, cod);
            }
        }

        NSDictionary *rec = @{
            @"0001": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassAudioSink]],
            @"0004": @[
                @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP], u16(kAVDTP)],
                @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16AVDTP], u16(0x0103)],
            ],
            @"0005": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassPublicBrowseGroup]],
            @"0009": @[@[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassAdvancedAudioDistribution],
                         u16(0x0103)]],
            @"0100": @"Bluetooth Audio Bridge",
            @"0311": u16(0x0002),  // Speaker
        };
        IOBluetoothSDPServiceRecord *sdp = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:rec];
        if (sdp) {
            BluetoothSDPServiceRecordHandle h = 0;
            [sdp getServiceRecordHandle:&h];
            logf_(@"Published A2DP Sink SDP record, handle=0x%08x", h);
        } else {
            logf_(@"FAILED to publish A2DP Sink SDP record");
        }

        // Control experiments: is SDP publishing blocked in general, or only for A2DP / PSM 0x19?
        NSDictionary *controls = @{
            @"SerialPort(RFCOMM)": @{
                @"0001": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassSerialPort]],
                @"0004": @[@[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP]],
                           @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16RFCOMM],
                             @{@"DataElementType": @1, @"DataElementSize": @1, @"DataElementValue": @3}]],
                @"0100": @"Probe SPP",
            },
            @"AudioSink, no protocol list": @{
                @"0001": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassAudioSink]],
                @"0100": @"Probe Sink NoProto",
            },
            @"AudioSink, L2CAP PSM 0x19 only (no AVDTP entry)": @{
                @"0001": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassAudioSink]],
                @"0004": @[@[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP], u16(kAVDTP)]],
                @"0100": @"Probe Sink PSM19",
            },
            @"SerialPort-class, L2CAP PSM 0x19": @{
                @"0001": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassSerialPort]],
                @"0004": @[@[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP], u16(kAVDTP)]],
                @"0100": @"Probe SPP PSM19",
            },
            @"Custom L2CAP PSM 0x1001": @{
                @"0001": @[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassAudioSink]],
                @"0004": @[@[[IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16L2CAP], u16(0x1001)]],
                @"0100": @"Probe Sink PSM1001",
            },
        };
        for (NSString *name in controls) {
            IOBluetoothSDPServiceRecord *r = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:controls[name]];
            logf_(@"Control SDP '%@': %@", name, r ? @"published" : @"FAILED");
            [r removeServiceRecord];
        }

        Probe *p = [Probe new];
        id n1 = [IOBluetoothDevice registerForConnectNotifications:p selector:@selector(deviceConnected:device:)];
        id n2 = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:p
                                                                   selector:@selector(l2capOpened:channel:)
                                                                    withPSM:kAVDTP
                                                                  direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
        id n3 = [IOBluetoothL2CAPChannel registerForChannelOpenNotifications:p
                                                                   selector:@selector(l2capOpened:channel:)];
        logf_(@"Notifications registered: connect=%d avdtp=%d anyL2CAP=%d", n1 != nil, n2 != nil, n3 != nil);
        logf_(@"Listening for %d s. Pair/connect from the other device now.", seconds);

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];

        [sdp removeServiceRecord];
        logf_(@"Done. SDP record removed. CoD now 0x%06x", hc.classOfDevice);
    }
    return 0;
}
