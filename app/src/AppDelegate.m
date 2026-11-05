#import "AppDelegate.h"
#import "SinkSession.h"
#import "AACPlayer.h"
#import "Log.h"
#import <IOBluetooth/IOBluetooth.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString *const kSourceKey = @"sourceAddress";
static NSString *const kOutputKey = @"outputDeviceUID";
static NSString *const kAutoKey = @"autoConnect";
static NSString *const kVolumeKey = @"volume";

@interface AppDelegate () <NSMenuDelegate, SinkSessionDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenu *menu;
@property(strong) NSMenuItem *statusLine, *detailLine;
@property(strong) SinkSession *session;
@property(strong) NSTimer *retryTimer, *uiTimer;
@property int failures;
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

    if (!self.sourceAddress) self.sourceAddress = [self guessSource];

    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(didWake:)
                                                           name:NSWorkspaceDidWakeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(willSleep:)
                                                           name:NSWorkspaceWillSleepNotification object:nil];
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

- (NSString *)guessSource {
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
        if ([d.name rangeOfString:@"Fire TV" options:NSCaseInsensitiveSearch].location != NSNotFound) return d.addressString;
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices)
        if (d.deviceClassMajor == kBluetoothDeviceClassMajorAudio) return d.addressString;
    return nil;
}

- (NSString *)sourceName {
    NSString *a = self.sourceAddress;
    if (!a) return nil;
    return [IOBluetoothDevice deviceWithAddressString:a].name ?: a;
}

#pragma mark - connection management

- (void)connectNow {
    [self.retryTimer invalidate];
    self.retryTimer = nil;
    if (!self.autoConnect || self.session || !self.sourceAddress) { [self refreshUI]; return; }
    SinkSession *s = [[SinkSession alloc] initWithAddress:self.sourceAddress];
    s.delegate = self;
    s.outputDeviceUID = self.outputUID;
    s.volume = self.volume;
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
        if (![s.endReason isEqualToString:@"Stopped"]) self.lastError = s.endReason;
        if (self.autoConnect) {
            if (s.everConnected) {
                [self scheduleRetry:2];
            } else {
                self.failures++;
                [self scheduleRetry:MIN(60, 5 * pow(2, MIN(self.failures - 1, 4)))];
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

#pragma mark - UI

- (NSString *)stateText {
    SinkSession *s = self.session;
    NSString *name = self.sourceName ?: @"source";
    if (!self.sourceAddress) return @"No source selected";
    if (!self.autoConnect) return @"Off";
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
    self.statusLine.title = [self stateText];
    NSString *detail = [self detailText];
    self.detailLine.title = detail ?: @"";
    self.detailLine.hidden = detail == nil;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];

    self.statusLine = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.statusLine.enabled = NO;
    [menu addItem:self.statusLine];
    self.detailLine = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    self.detailLine.enabled = NO;
    [menu addItem:self.detailLine];
    [self refreshUI];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *toggle = [[NSMenuItem alloc] initWithTitle:@"Receive Audio" action:@selector(toggleAuto:) keyEquivalent:@""];
    toggle.target = self;
    toggle.state = self.autoConnect ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:toggle];
    NSMenuItem *reconnect = [[NSMenuItem alloc] initWithTitle:@"Reconnect Now" action:@selector(reconnect:) keyEquivalent:@""];
    reconnect.target = self;
    reconnect.enabled = self.autoConnect && self.sourceAddress != nil;
    [menu addItem:reconnect];
    [menu addItem:NSMenuItem.separatorItem];

    // Volume slider
    NSMenuItem *volHeader = [[NSMenuItem alloc] initWithTitle:@"Volume" action:nil keyEquivalent:@""];
    volHeader.enabled = NO;
    [menu addItem:volHeader];
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 28)];
    NSSlider *slider = [NSSlider sliderWithValue:self.volume minValue:0 maxValue:1 target:self action:@selector(volumeChanged:)];
    slider.frame = NSMakeRect(18, 4, 204, 20);
    slider.continuous = YES;
    [v addSubview:slider];
    NSMenuItem *volItem = [NSMenuItem new];
    volItem.view = v;
    [menu addItem:volItem];
    [menu addItem:NSMenuItem.separatorItem];

    // Source device
    NSMenuItem *srcItem = [[NSMenuItem alloc] initWithTitle:@"Source" action:nil keyEquivalent:@""];
    NSMenu *src = [NSMenu new];
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:d.name ?: d.addressString action:@selector(pickSource:) keyEquivalent:@""];
        i.target = self;
        i.representedObject = d.addressString;
        i.state = [d.addressString isEqualToString:self.sourceAddress] ? NSControlStateValueOn : NSControlStateValueOff;
        [src addItem:i];
    }
    if (src.numberOfItems == 0) [src addItemWithTitle:@"No paired devices" action:nil keyEquivalent:@""];
    srcItem.submenu = src;
    [menu addItem:srcItem];

    // Output device
    NSMenuItem *outItem = [[NSMenuItem alloc] initWithTitle:@"Output" action:nil keyEquivalent:@""];
    NSMenu *outMenu = [NSMenu new];
    NSMenuItem *def = [[NSMenuItem alloc] initWithTitle:@"System Default" action:@selector(pickOutput:) keyEquivalent:@""];
    def.target = self;
    def.state = self.outputUID ? NSControlStateValueOff : NSControlStateValueOn;
    [outMenu addItem:def];
    [outMenu addItem:NSMenuItem.separatorItem];
    for (NSDictionary *d in [AACPlayer outputDevices]) {
        NSMenuItem *i = [[NSMenuItem alloc] initWithTitle:d[@"name"] action:@selector(pickOutput:) keyEquivalent:@""];
        i.target = self;
        i.representedObject = d[@"uid"];
        i.state = [d[@"uid"] isEqualToString:self.outputUID] ? NSControlStateValueOn : NSControlStateValueOff;
        [outMenu addItem:i];
    }
    outItem.submenu = outMenu;
    [menu addItem:outItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:login];
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
}

- (void)menuWillOpen:(NSMenu *)menu {
    self.uiTimer = [NSTimer timerWithTimeInterval:1 target:self selector:@selector(refreshUI) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.uiTimer forMode:NSRunLoopCommonModes];
}

- (void)menuDidClose:(NSMenu *)menu {
    [self.uiTimer invalidate];
    self.uiTimer = nil;
}

#pragma mark - actions

- (void)toggleAuto:(id)sender {
    BOOL on = !self.autoConnect;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kAutoKey];
    BABLog(@"Receive Audio %@", on ? @"on" : @"off");
    if (on) { self.failures = 0; [self connectNow]; }
    else { [self.retryTimer invalidate]; self.retryTimer = nil; [self.session stop]; }
    [self refreshUI];
}

- (void)reconnect:(id)sender {
    self.failures = 0;
    if (self.session) { [self.session stop]; }   // Ended -> retry in 2 s if it was connected
    else [self connectNow];
}

- (void)volumeChanged:(NSSlider *)s {
    [NSUserDefaults.standardUserDefaults setFloat:s.floatValue forKey:kVolumeKey];
    self.session.volume = s.floatValue;
}

- (void)pickSource:(NSMenuItem *)item {
    if ([item.representedObject isEqualToString:self.sourceAddress]) return;
    self.sourceAddress = item.representedObject;
    BABLog(@"Source set to %@", self.sourceName);
    self.failures = 0;
    SinkSession *old = self.session;
    self.session = nil;
    [old stop];
    [self connectNow];
}

- (void)pickOutput:(NSMenuItem *)item {
    NSString *uid = item.representedObject;
    if (uid) [NSUserDefaults.standardUserDefaults setObject:uid forKey:kOutputKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:kOutputKey];
    self.session.outputDeviceUID = uid;
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
