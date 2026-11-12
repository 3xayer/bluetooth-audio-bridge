// Stall-test triggers: each mode starts one kind of system activity for a few seconds, so
// stall-test.py can check which of them disturbs the incoming A2DP stream.
//   --trigger ble <s>         BLE scan with duplicates (like sharingd's high-rate scans)
//   --trigger ble-nodup <s>   BLE scan without duplicates
//   --trigger inquiry <s>     classic Bluetooth inquiry (device search)
//   --trigger wifi <s>        Wi-Fi scans, back to back
//   --trigger awdl <s>        Bonjour browse over peer-to-peer (brings up AWDL, as AirDrop does)
//   --trigger useractivity    declare user activity (what macOS does on input)
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import <CoreWLAN/CoreWLAN.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

void probeLog(NSString *fmt, ...);

// Private IOBluetooth methods (signatures from the ObjC runtime).
@interface NSObject (BABPrivateBT)
- (uint16_t)connectionHandle;
- (BOOL)highPriority;
- (void)setHighPriority:(BOOL)v;
- (void)setMidPriority:(BOOL)v;
- (uint8_t)streamingState;
- (void)setStreamingState:(uint8_t)v;
- (void)enableHighPower:(BOOL)v;
- (int)BluetoothHCIChangeConnectionPriority:(uint16_t)handle option:(uint8_t)option;
@end

@interface TriggerBLE : NSObject <CBCentralManagerDelegate>
@property BOOL dups;
@property int seen;
@property CBCentralManager *cm;
@end
@implementation TriggerBLE
- (void)centralManagerDidUpdateState:(CBCentralManager *)c {
    probeLog(@"BLE state %ld", (long)c.state);
    if (c.state == CBManagerStatePoweredOn)
        [c scanForPeripheralsWithServices:nil options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @(self.dups)}];
}
- (void)centralManager:(CBCentralManager *)c didDiscoverPeripheral:(CBPeripheral *)p
     advertisementData:(NSDictionary *)ad RSSI:(NSNumber *)rssi { self.seen++; }
@end

@interface TriggerInquiry : NSObject <IOBluetoothDeviceInquiryDelegate>
@property int found;
@property BOOL done;
@end
@implementation TriggerInquiry
- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)s device:(IOBluetoothDevice *)d { self.found++; }
- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry *)s error:(IOReturn)e aborted:(BOOL)a {
    probeLog(@"inquiry complete err 0x%x aborted %d", e, a);
    self.done = YES;
}
@end

@interface TriggerBrowse : NSObject <NSNetServiceBrowserDelegate>
@property int found;
@end
@implementation TriggerBrowse
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didFindService:(NSNetService *)s moreComing:(BOOL)m { self.found++; }
- (void)netServiceBrowser:(NSNetServiceBrowser *)b didNotSearch:(NSDictionary *)e { probeLog(@"browse error %@", e); }
@end

static void runFor(double s) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]]; }

int triggerMain(int argc, const char *argv[]) {
    if (argc < 3) { probeLog(@"usage: --trigger <mode> [seconds]"); return 2; }
    const char *mode = argv[2];
    double secs = argc >= 4 ? atof(argv[3]) : 8;
    probeLog(@"trigger %s %.0fs", mode, secs);
    if (!strcmp(mode, "ble") || !strcmp(mode, "ble-nodup")) {
        TriggerBLE *t = [TriggerBLE new];
        t.dups = !strcmp(mode, "ble");
        t.cm = [[CBCentralManager alloc] initWithDelegate:t queue:nil];
        runFor(secs);
        [t.cm stopScan];
        probeLog(@"BLE advertisements seen: %d", t.seen);
    } else if (!strcmp(mode, "inquiry")) {
        TriggerInquiry *t = [TriggerInquiry new];
        IOBluetoothDeviceInquiry *q = [IOBluetoothDeviceInquiry inquiryWithDelegate:t];
        q.inquiryLength = (uint8_t)MAX(1, MIN(60, secs));
        q.updateNewDeviceNames = NO;
        probeLog(@"inquiry start 0x%x", [q start]);
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs + 3];
        while (!t.done && end.timeIntervalSinceNow > 0) runFor(0.2);
        [q stop];
        probeLog(@"inquiry found %d", t.found);
    } else if (!strcmp(mode, "wifi")) {
        CWInterface *wi = CWWiFiClient.sharedWiFiClient.interface;
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:secs];
        int scans = 0;
        while (end.timeIntervalSinceNow > 0) {
            NSError *err = nil;
            NSSet *r = [wi scanForNetworksWithName:nil error:&err];
            scans++;
            probeLog(@"wifi scan %d: %lu networks %@", scans, (unsigned long)r.count, err ?: @"");
            if (err) break;
        }
    } else if (!strcmp(mode, "awdl")) {
        TriggerBrowse *t = [TriggerBrowse new];
        NSNetServiceBrowser *b = [NSNetServiceBrowser new];
        b.includesPeerToPeer = YES;
        b.delegate = t;
        [b searchForServicesOfType:@"_airdrop._tcp." inDomain:@"local."];
        runFor(secs);
        [b stop];
        probeLog(@"awdl browse found %d", t.found);
    } else if (!strcmp(mode, "useractivity")) {
        IOPMAssertionID a = 0;
        IOReturn r = IOPMAssertionDeclareUserActivity(CFSTR("stall test"), kIOPMUserActiveLocal, &a);
        probeLog(@"declare user activity -> 0x%x", r);
        runFor(1);
        if (a) IOPMAssertionRelease(a);
    } else if (!strncmp(mode, "prio-", 5)) {
        // Experiments: ask the stack to favour the A2DP link. argv[3] = device address, argv[4] = value.
        if (argc < 5) { probeLog(@"usage: --trigger prio-<kind> <address> <value>"); return 2; }
        // IOBluetooth's first use waits for the main queue, so create the device off the main thread.
        __block IOBluetoothDevice *d = nil;
        NSString *addr = @(argv[3]);
        dispatch_async(dispatch_get_global_queue(0, 0), ^{ d = [IOBluetoothDevice deviceWithAddressString:addr]; });
        for (int i = 0; i < 300 && !d; i++) runFor(0.1);
        if (!d) { probeLog(@"no device"); return 1; }
        int v = atoi(argv[4]);
        const char *kind = mode + 5;
        id dd = d;
        probeLog(@"device %@ connected %d handle 0x%x highPriority %d streamingState %d", d.addressString, d.isConnected,
                 [dd connectionHandle], [dd highPriority], [dd streamingState]);
        if (!strcmp(kind, "high")) [dd setHighPriority:v != 0];
        else if (!strcmp(kind, "mid")) [dd setMidPriority:v != 0];
        else if (!strcmp(kind, "streaming")) [dd setStreamingState:(uint8_t)v];
        else if (!strcmp(kind, "power")) [dd enableHighPower:v != 0];
        else if (!strcmp(kind, "hci")) {
            id hc = IOBluetoothHostController.defaultController;
            int r = [hc BluetoothHCIChangeConnectionPriority:[dd connectionHandle] option:(uint8_t)v];
            probeLog(@"HCI change connection priority -> 0x%x", r);
        } else { probeLog(@"unknown prio kind"); return 2; }
        runFor(1);
        probeLog(@"after: highPriority %d streamingState %d", [dd highPriority], [dd streamingState]);
        runFor(secs > 0 && argc >= 6 ? atof(argv[5]) : 0);
    } else {
        probeLog(@"unknown trigger %s", mode);
        return 2;
    }
    probeLog(@"trigger %s done", mode);
    return 0;
}
