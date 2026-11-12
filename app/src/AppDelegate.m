#import "AppDelegate.h"
#import "SinkSession.h"
#import "AACPlayer.h"
#import "AVRCP.h"
#import "MenuViews.h"
#import "SystemVolume.h"
#import <MediaPlayer/MediaPlayer.h>
#import "Log.h"
#import <IOBluetooth/IOBluetooth.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString *const kSourceKey = @"sourceAddress";
static NSString *const kOutputKey = @"outputDeviceUID";
static NSString *const kAutoKey = @"autoConnect";
static NSString *const kVolumeKey = @"volume";
static NSString *const kAutoDevicesKey = @"autoConnectDevices";   // addresses that connect on their own
static NSString *const kSBCKey = @"sbcEnabled";

@interface AppDelegate () <NSMenuDelegate, SinkSessionDelegate, BABAVRCPDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenu *menu;
@property(strong) NSMenuItem *statusLine, *detailLine;
@property(strong) SinkSession *session;
@property(strong) NSTimer *retryTimer, *uiTimer;
@property int failures;
@property(copy) NSString *target;         // device being connected / connected
@property(copy) NSString *manualTarget;   // picked under "Connect To"; nil = take turns with the automatic devices
@property int autoIndex, manualFailures;
@property(strong) BABSystemVolume *macVolume;
// views of the open menu, updated live
@property(strong) BABVolumeView *volumeView;
@property(strong) BABNowPlayingView *nowPlayingView;
@property(strong) NSArray<NSMenuItem *> *nowPlayingItems;   // separator + card, while shown
@property BOOL menuIsOpen;
@property(copy) NSString *disconnectedByUser;   // skipped by auto-connect until picked again
@property(strong) NSArray<BABMenuRow *> *connectRows, *autoRows;
@property(strong) NSMutableArray<BABMenuRow *> *liveRows;   // rows whose check / enabled state follows the app
@property(copy) NSString *lastError;
@end

@implementation AppDelegate

#pragma mark - lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:bid].count > 1) {
        BABLog(@"Already running; exiting");
        [NSApp terminate:nil];
        return;
    }
    [NSUserDefaults.standardUserDefaults registerDefaults:@{kAutoKey: @YES, kVolumeKey: @1.0}];
    BABLog(@"Bluetooth Audio Bridge started (version %@)", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]);

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.menu = [NSMenu new];
    self.menu.delegate = self;
    self.menu.autoenablesItems = NO;
    self.statusItem.menu = self.menu;
    [self updateIcon];

    if (![NSUserDefaults.standardUserDefaults arrayForKey:kAutoDevicesKey]) {
        // First run with per-device auto-connect: Fire TVs connect automatically, as before.
        NSMutableArray *autos = [NSMutableArray array];
        for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
            if ([d.name rangeOfString:@"Fire TV" options:NSCaseInsensitiveSearch].location != NSNotFound) [autos addObject:d.addressString];
        if (autos.count == 0 && (self.sourceAddress ?: [self guessSource])) [autos addObject:self.sourceAddress ?: [self guessSource]];
        [NSUserDefaults.standardUserDefaults setObject:autos forKey:kAutoDevicesKey];
        BABLog(@"Automatic sources: %@", autos);
    }

    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:)
                                                           name:NSWorkspaceDidWakeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(willSleep:)
                                                           name:NSWorkspaceWillSleepNotification object:nil];
    [self setUpMediaKeys];
    __weak AppDelegate *ws = self;
    self.macVolume = [[BABSystemVolume alloc] initWithDeviceUID:self.outputUID changeHandler:^(float v) { [ws macVolumeChanged:v]; }];
    [self connectNow];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self.session stop];
    // give the AVDTP CLOSE a moment to go out
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
}

#pragma mark - settings

- (NSString *)sourceAddress { return [NSUserDefaults.standardUserDefaults stringForKey:kSourceKey]; }
- (void)setSourceAddress:(NSString *)a { [NSUserDefaults.standardUserDefaults setObject:a forKey:kSourceKey]; }
- (NSString *)outputUID { return [NSUserDefaults.standardUserDefaults stringForKey:kOutputKey]; }
- (BOOL)autoConnect { return [NSUserDefaults.standardUserDefaults boolForKey:kAutoKey]; }
- (float)volume { return [NSUserDefaults.standardUserDefaults floatForKey:kVolumeKey]; }
- (NSArray<NSString *> *)autoDevices { return [NSUserDefaults.standardUserDefaults arrayForKey:kAutoDevicesKey] ?: @[]; }
- (void)setAutoDevices:(NSArray<NSString *> *)a { [NSUserDefaults.standardUserDefaults setObject:a forKey:kAutoDevicesKey]; }

// Paired devices that can send audio: an A2DP source record in their (cached) SDP services, or no
// service information at all (then we can't tell, so list them).
- (NSArray<IOBluetoothDevice *> *)sourceDevices {
    NSMutableArray *out = [NSMutableArray array];
    IOBluetoothSDPUUID *audioSource = [IOBluetoothSDPUUID uuid16:kBluetoothSDPUUID16ServiceClassAudioSource];
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
        if (d.services.count == 0 || [d getServiceRecordForUUID:audioSource] ||
            [d.addressString isEqualToString:self.target] || [self.autoDevices containsObject:d.addressString])
            [out addObject:d];
    return out;
}

- (NSString *)nameFor:(NSString *)address {
    return address ? [IOBluetoothDevice deviceWithAddressString:address].name ?: address : nil;
}

- (NSString *)guessSource {
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
        if ([d.name rangeOfString:@"Fire TV" options:NSCaseInsensitiveSearch].location != NSNotFound) return d.addressString;
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
        if (d.deviceClassMajor == kBluetoothDeviceClassMajorAudio) return d.addressString;
    return nil;
}

- (NSString *)sourceName { return [self nameFor:self.target]; }

#pragma mark - connection management

// Connects to the device picked under "Connect To", or else takes turns with the automatic devices.
- (void)connectNow {
    [self.retryTimer invalidate];
    self.retryTimer = nil;
    if (!self.autoConnect || self.session) { [self refreshUI]; return; }
    NSString *address = self.manualTarget;
    if (!address) {
        NSMutableArray *autos = [self.autoDevices mutableCopy];
        if (self.disconnectedByUser) [autos removeObject:self.disconnectedByUser];
        if (autos.count == 0) { self.target = nil; [self refreshUI]; return; }
        self.autoIndex %= (int)autos.count;
        address = autos[self.autoIndex];
    }
    self.target = address;
    self.sourceAddress = address;
    SinkSession *s = [[SinkSession alloc] initWithAddress:address];
    s.delegate = self;
    s.outputDeviceUID = self.outputUID;
    s.volume = self.playerVolume;
    self.session = s;
    [s start];
    [self refreshUI];
}

- (void)scheduleRetry:(NSTimeInterval)delay {
    [self.retryTimer invalidate];
    BABLog(@"Next connection attempt in %.0f s", delay);
    self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:delay target:self selector:@selector(connectNow)
                                                     userInfo:nil repeats:NO];
}

- (void)sinkSessionDidChangeState:(SinkSession *)s {
    if (s != self.session) return;
    if (s.state == SinkStateReady || s.state == SinkStateStreaming) { self.failures = 0; self.lastError = nil; }
    if (s.state == SinkStateEnded) {
        self.session = nil;
        [self updateNowPlaying];
        if (![s.endReason isEqualToString:@"Stopped"]) self.lastError = s.endReason;
        if (self.autoConnect) {
            if (s.everConnected) {
                self.manualFailures = 0;
                [self scheduleRetry:2];   // same device again
            } else if (self.manualTarget) {
                // A device picked by hand gets a few tries, then the automatic devices take over again.
                if (++self.manualFailures >= 3) {
                    BABLog(@"Giving up on %@", [self nameFor:self.manualTarget]);
                    self.lastError = [NSString stringWithFormat:@"Couldn't reach %@", [self nameFor:self.manualTarget]];
                    self.manualTarget = nil;
                    self.failures = 0;
                    [self scheduleRetry:1];
                } else {
                    [self scheduleRetry:5];
                }
            } else {
                // Try the next automatic device; after a full round, back off (5, 10, 20, 40, 60 s).
                NSUInteger n = MAX(self.autoDevices.count, 1);
                self.autoIndex = (self.autoIndex + 1) % (int)n;
                if (self.autoIndex != 0) {
                    [self scheduleRetry:1];
                } else {
                    self.failures++;
                    [self scheduleRetry:MIN(60, 5 * pow(2, MIN(self.failures - 1, 4)))];
                }
            }
        }
    }
    [self refreshUI];
}

- (void)didWake:(NSNotification *)n {
    BABLog(@"Woke from sleep");
    self.failures = 0;
    if (!self.session) [self scheduleRetry:3];
}

- (void)willSleep:(NSNotification *)n {
    BABLog(@"Going to sleep");
    [self.session stop];
}

#pragma mark - remote control (AVRCP) and media keys

- (void)sinkSessionDidOpenAVRCP:(SinkSession *)s {
    s.avrcp.delegate = self;
    s.avrcp.volume = self.shownVolume;
    [self refreshUI];
}

- (void)avrcpDidUpdateMedia:(BABAVRCP *)avrcp {
    [self updateNowPlaying];
    [self refreshUI];
}

- (void)avrcp:(BABAVRCP *)avrcp didSetVolume:(float)volume {
    [self setVolumeFromUser:volume];
}

#pragma mark - volume

// The volume control (menu slider, source's volume buttons) is the Mac's output volume when the
// output device has one; otherwise (e.g. some HDMI/DisplayPort outputs) it scales the received audio.
- (BOOL)usesMacVolume { return self.macVolume.settable; }
- (float)playerVolume { return self.usesMacVolume ? 1.0f : self.volume; }
- (float)shownVolume { return self.usesMacVolume ? self.macVolume.volume : self.volume; }

- (void)setVolumeFromUser:(float)v {
    if (self.usesMacVolume) {
        self.macVolume.volume = v;   // the change listener updates the slider and the source
    } else {
        [NSUserDefaults.standardUserDefaults setFloat:v forKey:kVolumeKey];
        self.session.volume = v;
        self.session.avrcp.volume = v;
        [self.volumeView setValue:v];
    }
}

- (void)macVolumeChanged:(float)v {
    if (!self.usesMacVolume) return;
    [self.volumeView setValue:v];
    self.session.avrcp.volume = v;   // keeps the phone's volume slider in step
}

// The keyboard's play/pause and track keys go to the "now playing" app, so show the source's title there.
- (void)updateNowPlaying {
    BABAVRCP *a = self.session.avrcp;
    MPNowPlayingInfoCenter *c = MPNowPlayingInfoCenter.defaultCenter;
    if (!a || (!a.title && a.playStatus == BABPlayStatusUnknown)) {
        c.nowPlayingInfo = nil;
        c.playbackState = MPNowPlayingPlaybackStateStopped;
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = a.title ?: self.sourceName ?: @"Bluetooth audio";
    if (a.artist) info[MPMediaItemPropertyArtist] = a.artist;
    if (a.album) info[MPMediaItemPropertyAlbumTitle] = a.album;
    c.nowPlayingInfo = info;
    c.playbackState = a.playStatus == BABPlayStatusPlaying ? MPNowPlayingPlaybackStatePlaying
                    : a.playStatus == BABPlayStatusPaused ? MPNowPlayingPlaybackStatePaused : MPNowPlayingPlaybackStateStopped;
}

- (MPRemoteCommandHandlerStatus)sendKey:(BABAVRCPKey)key {
    BABAVRCP *a = self.session.avrcp;
    if (!a) return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
    [a sendKey:key];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (BABAVRCPKey)toggleKey {
    return self.session.avrcp.playStatus == BABPlayStatusPlaying ? BABAVRCPKeyPause : BABAVRCPKeyPlay;
}

- (void)setUpMediaKeys {
    MPRemoteCommandCenter *c = MPRemoteCommandCenter.sharedCommandCenter;
    __weak AppDelegate *ws = self;
    [c.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { return [ws sendKey:BABAVRCPKeyPlay]; }];
    [c.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { return [ws sendKey:BABAVRCPKeyPause]; }];
    [c.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { return [ws sendKey:[ws toggleKey]]; }];
    [c.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { return [ws sendKey:BABAVRCPKeyNext]; }];
    [c.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { return [ws sendKey:BABAVRCPKeyPrevious]; }];
}

- (void)playPause:(id)sender { [self sendKey:[self toggleKey]]; }
- (void)nextTrack:(id)sender { [self sendKey:BABAVRCPKeyNext]; }
- (void)previousTrack:(id)sender { [self sendKey:BABAVRCPKeyPrevious]; }

#pragma mark - UI

- (NSString *)stateText {
    SinkSession *s = self.session;
    NSString *name = self.sourceName ?: @"source";
    if (!self.autoConnect) return @"Off";
    if (!self.target) return self.autoDevices.count ? @"Not connected" : @"No automatic source";
    switch (s ? s.state : SinkStateEnded) {
    case SinkStateIdle: case SinkStateConnecting: return [NSString stringWithFormat:@"Connecting to %@…", name];
    case SinkStateReady: return [NSString stringWithFormat:@"Connected to %@ (idle)", name];
    case SinkStateStreaming: return [NSString stringWithFormat:@"Playing from %@", name];
    case SinkStateEnded:
        return self.retryTimer ? [NSString stringWithFormat:@"Waiting for %@", name] : @"Not connected";
    }
    return @"";
}

- (NSString *)detailText {
    SinkSession *s = self.session;
    if (s.state == SinkStateStreaming)
        return [NSString stringWithFormat:@"%@ · %.0f kbit/s · %.0f ms delay", s.codecDescription ?: @"AAC", s.bitrateKbps, s.delayMs];
    if (s.state == SinkStateReady) return @"Waiting for audio";
    if (!s && self.lastError) return self.lastError;
    if (!s && !self.target && self.autoConnect) return @"Pick a device under Connect To";
    return nil;
}

- (void)updateIcon {
    SinkState st = self.session ? self.session.state : SinkStateEnded;
    NSString *sym = !self.autoConnect ? @"speaker.slash"
                  : st == SinkStateStreaming ? @"hifispeaker.fill"
                  : st == SinkStateReady ? @"hifispeaker"
                  : @"speaker";
    NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:@"Bluetooth Audio Bridge"];
    img.template = YES;
    self.statusItem.button.image = img;
    self.statusItem.button.appearsDisabled = (st != SinkStateStreaming && st != SinkStateReady);
    self.statusItem.button.toolTip = [self stateText];
}

- (void)refreshUI {
    [self updateIcon];
    [self refreshMenuViews];
    self.statusLine.title = [self stateText];
    NSString *detail = [self detailText];
    self.detailLine.title = detail ?: @"";
    self.detailLine.hidden = detail == nil;
}

- (NSMenuItem *)viewItem:(NSView *)v {
    NSMenuItem *i = [NSMenuItem new];
    i.view = v;
    return i;
}

- (NSMenuItem *)header:(NSString *)title {
    if (@available(macOS 14.0, *)) return [NSMenuItem sectionHeaderWithTitle:title];
    NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    i.enabled = NO;
    return i;
}

// Brings the open menu's custom views up to date (connection marks, title, play state).
// Shows the player card while the source offers remote control, also when that starts or stops
// with the menu open.
- (void)syncNowPlayingItem {
    BOOL want = self.session.avrcp != nil;
    if (want == (self.nowPlayingItems != nil) || !self.detailLine.menu) return;
    if (want) {
        __weak AppDelegate *ws = self;
        self.nowPlayingView = [[BABNowPlayingView alloc] initWithPrevious:^{ [ws previousTrack:nil]; }
                                                                playPause:^{ [ws playPause:nil]; }
                                                                     next:^{ [ws nextTrack:nil]; }];
        NSMenuItem *sep = NSMenuItem.separatorItem, *card = [self viewItem:self.nowPlayingView];
        NSInteger at = [self.menu indexOfItem:self.detailLine] + 1;
        [self.menu insertItem:sep atIndex:at];
        [self.menu insertItem:card atIndex:at + 1];
        self.nowPlayingItems = @[sep, card];
    } else {
        for (NSMenuItem *i in self.nowPlayingItems) if (i.menu) [self.menu removeItem:i];
        self.nowPlayingItems = nil;
        self.nowPlayingView = nil;
    }
}

// A row that keeps the menu open when clicked; its checkmark and enabled state are re-evaluated live.
- (NSMenuItem *)rowItem:(NSString *)title mark:(BABRowMark (^)(void))mark enabled:(BOOL (^)(void))enabled action:(void (^)(void))action {
    __weak AppDelegate *ws = self;
    BABMenuRow *r = [[BABMenuRow alloc] initWithTitle:title action:^(BABMenuRow *row) { action(); [ws refreshUI]; }];
    r.markProvider = mark;
    r.enabledProvider = enabled;
    [r refresh];
    [self.liveRows addObject:r];
    return [self viewItem:r];
}

- (void)refreshMenuViews {
    if (self.menuIsOpen) [self syncNowPlayingItem];
    for (BABMenuRow *r in self.liveRows) [r refresh];
    SinkSession *s = self.session;
    BOOL connected = s && (s.state == SinkStateReady || s.state == SinkStateStreaming);
    BOOL connecting = (s && !connected && s.state != SinkStateEnded) || (!s && self.retryTimer && self.manualTarget);
    for (BABMenuRow *r in self.connectRows) {
        BOOL mine = [r.identifier2 isEqualToString:self.target];
        r.mark = mine && connected ? BABRowMarkCheck : mine && connecting ? BABRowMarkSpinner : BABRowMarkNone;
        r.toolTip = r.mark == BABRowMarkNone ? nil : @"Click again to disconnect";
    }
    for (BABMenuRow *r in self.autoRows)
        r.mark = [self.autoDevices containsObject:r.identifier2] ? BABRowMarkCheck : BABRowMarkNone;
    BABAVRCP *a = s.avrcp;
    if (self.nowPlayingView) {
        NSString *title = a.title ?: (s.state == SinkStateStreaming ? @"Playing" : @"Not playing");
        NSString *sub = a.title ? (a.artist ?: a.album ?: self.sourceName) : self.sourceName;
        [self.nowPlayingView setTitle:title subtitle:sub playing:a.playStatus == BABPlayStatusPlaying];
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.menu) return;   // the device submenus are built along with the main menu
    [menu removeAllItems];
    self.liveRows = [NSMutableArray array];
    menu.minimumWidth = kBABMenuWidth;
    __weak AppDelegate *ws = self;

    self.statusLine = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.statusLine.enabled = NO;
    [menu addItem:self.statusLine];
    self.detailLine = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.detailLine.enabled = NO;
    [menu addItem:self.detailLine];

    // Player of the source: title, artist, previous / play-pause / next (inserted after the detail line)
    self.nowPlayingView = nil;
    self.nowPlayingItems = nil;
    [menu addItem:NSMenuItem.separatorItem];

    // Volume: the Mac's output volume (or the received audio's, if the output has no volume control)
    [menu addItem:[self header:self.usesMacVolume ? @"Volume" : @"Volume (received audio)"]];
    self.volumeView = [[BABVolumeView alloc] initWithValue:self.shownVolume action:^(float v) { [ws setVolumeFromUser:v]; }];
    [menu addItem:[self viewItem:self.volumeView]];
    [menu addItem:NSMenuItem.separatorItem];

    // Everything that only changes something in the app keeps the menu open (views instead of plain items).
    [menu addItem:[self rowItem:@"Receive Audio"
                           mark:^{ return ws.autoConnect ? BABRowMarkCheck : BABRowMarkNone; }
                        enabled:nil
                         action:^{ [ws toggleAuto:nil]; }]];
    [menu addItem:[self rowItem:@"Reconnect Now"
                           mark:nil
                        enabled:^{ return (BOOL)(ws.autoConnect && (ws.target != nil || ws.autoDevices.count > 0)); }
                         action:^{ [ws reconnect:nil]; }]];
    [menu addItem:NSMenuItem.separatorItem];

    // Source devices: connect now (spinner while connecting), and which ones connect on their own.
    // Rows are views, so clicking them keeps the submenu open.
    NSArray<IOBluetoothDevice *> *sources = [self sourceDevices];
    NSMutableArray *connectRows = [NSMutableArray array], *autoRows = [NSMutableArray array];
    NSMenu *src = [NSMenu new], *autoMenu = [NSMenu new];
    src.minimumWidth = autoMenu.minimumWidth = kBABMenuWidth;
    src.delegate = autoMenu.delegate = self;   // menu:willHighlightItem: drives the rows' highlight
    for (IOBluetoothDevice *d in sources) {
        NSString *address = d.addressString, *name = d.name ?: d.addressString;
        BABMenuRow *c = [[BABMenuRow alloc] initWithTitle:name action:^(BABMenuRow *r) { [ws connectTo:r.identifier2]; }];
        c.identifier2 = address;
        [connectRows addObject:c];
        [src addItem:[self viewItem:c]];
        BABMenuRow *a = [[BABMenuRow alloc] initWithTitle:name action:^(BABMenuRow *r) { [ws toggleAutoDevice:r.identifier2]; }];
        a.identifier2 = address;
        [autoRows addObject:a];
        [autoMenu addItem:[self viewItem:a]];
    }
    if (sources.count == 0) {
        [src addItemWithTitle:@"No paired audio sources" action:nil keyEquivalent:@""].enabled = NO;
        [autoMenu addItemWithTitle:@"No paired audio sources" action:nil keyEquivalent:@""].enabled = NO;
    }
    self.connectRows = connectRows;
    self.autoRows = autoRows;
    NSMenuItem *srcItem = [[NSMenuItem alloc] initWithTitle:@"Connect To" action:nil keyEquivalent:@""];
    srcItem.submenu = src;
    [menu addItem:srcItem];
    NSMenuItem *autoItem = [[NSMenuItem alloc] initWithTitle:@"Connect Automatically" action:nil keyEquivalent:@""];
    autoItem.submenu = autoMenu;
    [menu addItem:autoItem];

    // Output device
    NSMenuItem *outItem = [[NSMenuItem alloc] initWithTitle:@"Output" action:nil keyEquivalent:@""];
    NSMenu *outMenu = [NSMenu new];
    outMenu.minimumWidth = kBABMenuWidth;
    outMenu.delegate = self;
    [outMenu addItem:[self rowItem:@"System Default"
                              mark:^{ return ws.outputUID ? BABRowMarkNone : BABRowMarkCheck; }
                           enabled:nil
                            action:^{ [ws pickOutputUID:nil]; }]];
    [outMenu addItem:NSMenuItem.separatorItem];
    for (NSDictionary *d in [AACPlayer outputDevices]) {
        NSString *uid = d[@"uid"];
        [outMenu addItem:[self rowItem:d[@"name"]
                                  mark:^{ return [uid isEqualToString:ws.outputUID] ? BABRowMarkCheck : BABRowMarkNone; }
                               enabled:nil
                                action:^{ [ws pickOutputUID:uid]; }]];
    }
    outItem.submenu = outMenu;
    [menu addItem:outItem];
    [menu addItem:[self rowItem:@"Allow SBC (for devices without AAC)"
                           mark:^{ return [NSUserDefaults.standardUserDefaults boolForKey:kSBCKey] ? BABRowMarkCheck : BABRowMarkNone; }
                        enabled:nil
                         action:^{ [ws toggleSBC:nil]; }]];
    [menu addItem:NSMenuItem.separatorItem];

    [menu addItem:[self rowItem:@"Open at Login"
                           mark:^{ return SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? BABRowMarkCheck : BABRowMarkNone; }
                        enabled:nil
                         action:^{ [ws toggleLogin:nil]; }]];
    NSMenuItem *bt = [[NSMenuItem alloc] initWithTitle:@"Bluetooth Settings…" action:@selector(openBluetooth:) keyEquivalent:@""];
    bt.target = self;
    [menu addItem:bt];
    NSMenuItem *log = [[NSMenuItem alloc] initWithTitle:@"Show Log" action:@selector(showLog:) keyEquivalent:@""];
    log.target = self;
    [menu addItem:log];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Bluetooth Audio Bridge" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
    [self syncNowPlayingItem];
    [self refreshUI];
}

- (void)menu:(NSMenu *)menu willHighlightItem:(NSMenuItem *)item {
    [BABMenuRow highlightItem:item inMenu:menu];
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (menu != self.menu) return;
    self.menuIsOpen = YES;
    self.uiTimer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(refreshUI) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.uiTimer forMode:NSRunLoopCommonModes];
}

- (void)menuDidClose:(NSMenu *)menu {
    if (menu != self.menu) return;   // a submenu closed
    [self.uiTimer invalidate];
    self.uiTimer = nil;
    self.menuIsOpen = NO;
    self.volumeView = nil; self.nowPlayingView = nil; self.nowPlayingItems = nil; self.connectRows = nil; self.autoRows = nil;
    self.liveRows = nil;
}

#pragma mark - actions

- (void)toggleAuto:(id)sender {
    BOOL on = !self.autoConnect;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kAutoKey];
    BABLog(@"Receive Audio %@", on ? @"on" : @"off");
    if (on) { self.failures = 0; self.manualTarget = nil; self.disconnectedByUser = nil; [self connectNow]; }
    else { [self.retryTimer invalidate]; self.retryTimer = nil; [self.session stop]; }
    [self refreshUI];
}

- (void)reconnect:(id)sender {
    self.failures = 0;
    if (self.session) { [self.session stop]; }   // Ended -> retry in 2 s if it was connected
    else [self connectNow];
}


// Click a device to connect to it; click the connected (or connecting) device again to disconnect.
- (void)connectTo:(NSString *)address {
    BOOL active = [address isEqualToString:self.target] && (self.session || (self.retryTimer && self.manualTarget));
    if (active) {
        BABLog(@"Disconnecting from %@ on request", [self nameFor:address]);
        self.disconnectedByUser = address;
        self.manualTarget = nil;
        self.target = nil;
        self.lastError = nil;
        [self.retryTimer invalidate];
        self.retryTimer = nil;
        SinkSession *old = self.session;
        self.session = nil;   // ended on purpose: no reconnect to it
        [old stop];
        [self updateNowPlaying];
        [self connectNow];    // other automatic devices, if any
        return;
    }
    BABLog(@"Connecting to %@ on request", [self nameFor:address]);
    if ([self.disconnectedByUser isEqualToString:address]) self.disconnectedByUser = nil;
    self.manualTarget = address;
    self.manualFailures = 0;
    self.failures = 0;
    self.lastError = nil;
    if (!self.autoConnect) [NSUserDefaults.standardUserDefaults setBool:YES forKey:kAutoKey];
    SinkSession *old = self.session;
    self.session = nil;
    [old stop];
    [self connectNow];
}

- (void)toggleAutoDevice:(NSString *)address {
    NSMutableArray *autos = [self.autoDevices mutableCopy];
    BOOL on = ![autos containsObject:address];
    if (on) [autos addObject:address]; else [autos removeObject:address];
    self.autoDevices = autos;
    BABLog(@"%@ connects automatically: %@", [self nameFor:address], on ? @"yes" : @"no");
    if (on && [self.disconnectedByUser isEqualToString:address]) self.disconnectedByUser = nil;
    if (on && !self.session) { self.failures = 0; self.autoIndex = (int)autos.count - 1; [self connectNow]; }
    [self refreshUI];
}

- (void)toggleSBC:(id)sender {
    BOOL on = ![NSUserDefaults.standardUserDefaults boolForKey:kSBCKey];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kSBCKey];
    BABLog(@"SBC %@ (used only when a device has no AAC; applies from the next connection)", on ? @"allowed" : @"off");
}

- (void)pickOutputUID:(NSString *)uid {
    if (uid) [NSUserDefaults.standardUserDefaults setObject:uid forKey:kOutputKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kOutputKey];
    self.session.outputDeviceUID = uid;
    self.macVolume.deviceUID = uid;
    self.session.volume = self.playerVolume;
    BABLog(@"Output set to %@", uid ?: @"system default");
}

- (void)toggleLogin:(id)sender {
    NSError *err = nil;
    SMAppService *svc = SMAppService.mainAppService;
    BOOL ok = svc.status == SMAppServiceStatusEnabled ? [svc unregisterAndReturnError:&err] : [svc registerAndReturnError:&err];
    if (!ok) {
        BABLog(@"Open at Login change failed: %@", err);
        NSAlert *a = [NSAlert new];
        a.messageText = @"Couldn't change Open at Login";
        a.informativeText = err.localizedDescription ?: @"Unknown error";
        [NSApp activateIgnoringOtherApps:YES];
        [a runModal];
    }
}

- (void)openBluetooth:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.BluetoothSettings"]];
}

- (void)showLog:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:BABLogPath()]];
}

@end
