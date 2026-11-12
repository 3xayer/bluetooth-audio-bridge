// Without priority, the controller schedules our incoming audio like bulk data. When macOS runs an
// aggressive BLE scan (30 ms out of every 40 ms, for AirPods automatic switching after user input) or
// a device search, the source then gets only ~50-60% of the stream through for 10-15 s.
//
// Private API: bluetoothd's CBMsgIdPeripheralSetHighPriorityStream (201), the message
// -[CBPeripheral setHighPriorityStream:duration:] sends, looks up the ACL link of any device UUID,
// classic ones included ("Enabling high priority stream ... for device UUID ..."). It only needs an
// ordinary CoreBluetooth central session. Measured on macOS 27 with a classic device search running:
// without it 11 s at ~110 kbit/s and ~10 underruns; with it no drop at all. The priority stays on
// until switched off (the duration, a 16-bit millisecond count, doesn't end it), but it's refreshed
// anyway in case a future version honours the duration.
#import <CoreBluetooth/CoreBluetooth.h>
#import "LinkPriority.h"
#import "Log.h"

static const uint16_t kMsgSetHighPriorityStream = 201;
static const int kDurationMs = 65000;
static const NSTimeInterval kRefreshSeconds = 50;

@interface CBManager (BABPrivate)
- (BOOL)sendMsg:(uint16_t)msg args:(NSDictionary *)args;
@end

@interface BABLinkPriority () <CBCentralManagerDelegate>
@end

@implementation BABLinkPriority {
    CBCentralManager *_central;
    NSUUID *_peer;      // wanted state: priority for this peer (nil = off)
    NSUUID *_applied;   // what bluetoothd was last told
    NSUUID *_offPeer;   // priority to clear once the central is powered on
    NSTimer *_refresh;
}

+ (instancetype)shared {
    static BABLinkPriority *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [BABLinkPriority new]; });
    return s;
}

- (void)enableForPeer:(NSUUID *)peer {
    if (!peer) return;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"linkPriority"] && ![d boolForKey:@"linkPriority"]) {
        // Turned off (`defaults write local.bluetooth-audio-bridge linkPriority -bool NO`): clear any
        // priority a previous run left behind, since bluetoothd keeps it until told otherwise.
        _offPeer = peer;
        if (!_central) _central = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        if (_central.state == CBManagerStatePoweredOn) { [self send:peer on:NO]; _offPeer = nil; }
        return;
    }
    if (_applied && ![_applied isEqual:peer]) [self send:_applied on:NO];
    _peer = peer;
    [self apply];
    if (!_refresh) {
        _refresh = [NSTimer scheduledTimerWithTimeInterval:kRefreshSeconds target:self selector:@selector(apply)
                                                  userInfo:nil repeats:YES];
        _refresh.tolerance = 5;
    }
}

- (void)disable {
    [_refresh invalidate]; _refresh = nil;
    _peer = nil;
    if (_applied) [self send:_applied on:NO];
    _applied = nil;
}

- (void)apply {
    if (!_peer) return;
    if (!_central) _central = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    if (_central.state == CBManagerStatePoweredOn) [self send:_peer on:YES];
    // otherwise centralManagerDidUpdateState: applies it
}

- (void)send:(NSUUID *)peer on:(BOOL)on {
    if (!_central || _central.state != CBManagerStatePoweredOn) return;
    if (![_central respondsToSelector:@selector(sendMsg:args:)]) { BABLog(@"Link priority unavailable"); return; }
    NSMutableDictionary *args = [@{@"kCBMsgArgDeviceUUID": peer, @"kCBMsgArgSetHighPriorityStream": @(on)} mutableCopy];
    if (on) args[@"kCBMsgArgHighPriorityStreamDuration"] = @(kDurationMs);
    BOOL ok = [_central sendMsg:kMsgSetHighPriorityStream args:args];
    BOOL first = on && ![_applied isEqual:peer];
    if (first || !on || !ok) BABLog(@"Link priority %@ for %@%@", on ? @"on" : @"off", peer.UUIDString, ok ? @"" : @" (send failed)");
    _applied = on && ok ? peer : (on ? _applied : nil);
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) {
        if (_offPeer) { [self send:_offPeer on:NO]; _offPeer = nil; }
        _applied = nil;   // bluetoothd may have restarted: tell it again
        [self apply];
    }
}

@end
