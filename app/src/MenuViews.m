#import "MenuViews.h"

static NSTextField *label(NSString *s, NSFont *font, NSColor *color) {
    NSTextField *t = [NSTextField labelWithString:s ?: @""];
    t.font = font;
    t.textColor = color;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    t.cell.truncatesLastVisibleLine = YES;
    t.maximumNumberOfLines = 1;
    return t;
}

static NSImage *symbol(NSString *name, CGFloat size, NSFontWeight weight) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    return [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:weight]];
}

#pragma mark - row

@implementation BABMenuRow {
    void (^_action)(BABMenuRow *);
    NSTextField *_title;
    NSImageView *_check;
    NSProgressIndicator *_spinner;
}

- (instancetype)initWithTitle:(NSString *)title action:(void (^)(BABMenuRow *))action {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kBABMenuWidth, 22)])) {
        _action = [action copy];
        _enabled = YES;
        _title = label(title, [NSFont menuFontOfSize:0], NSColor.labelColor);
        _title.frame = NSMakeRect(28, 3, kBABMenuWidth - 40, 16);
        [self addSubview:_title];
        _check = [NSImageView imageViewWithImage:symbol(@"checkmark", 11, NSFontWeightSemibold)];
        _check.frame = NSMakeRect(10, 3, 14, 16);
        _check.contentTintColor = NSColor.labelColor;
        _check.hidden = YES;
        [self addSubview:_check];
        _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(10, 4, 14, 14)];
        _spinner.style = NSProgressIndicatorStyleSpinning;
        _spinner.controlSize = NSControlSizeSmall;
        _spinner.displayedWhenStopped = NO;
        _spinner.usesThreadedAnimation = YES;
        [self addSubview:_spinner];
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                             owner:self userInfo:nil]];
    }
    return self;
}

- (void)setMark:(BABRowMark)mark {
    if (_mark == mark) return;
    _mark = mark;
    _check.hidden = mark != BABRowMarkCheck;
    if (mark == BABRowMarkSpinner) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
}

// Menus don't redraw item views when their highlight changes, and mouse-exit events don't reliably
// reach them. So a row highlights itself on mouse-enter and clears its siblings, and the menu's
// delegate (menu:willHighlightItem:) sets the state too, which also clears it when the mouse leaves.
- (void)setHighlighted:(BOOL)highlighted {
    highlighted = highlighted && _enabled;
    if (_highlighted == highlighted) return;
    _highlighted = highlighted;
    [self updateColors];
}

- (void)setEnabled:(BOOL)enabled {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!enabled) _highlighted = NO;
    [self updateColors];
}

- (void)updateColors {
    NSColor *c = !_enabled ? NSColor.disabledControlTextColor
               : _highlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor;
    _title.textColor = c;
    _check.contentTintColor = c;
    self.needsDisplay = YES;
}

- (void)refresh {
    if (self.markProvider) self.mark = self.markProvider();
    if (self.enabledProvider) self.enabled = self.enabledProvider();
}

+ (void)highlightItem:(NSMenuItem *)item inMenu:(NSMenu *)menu {
    for (NSMenuItem *i in menu.itemArray)
        if ([i.view isKindOfClass:BABMenuRow.class]) ((BABMenuRow *)i.view).highlighted = (i == item);
}

- (void)mouseEntered:(NSEvent *)e { [BABMenuRow highlightItem:self.enclosingMenuItem inMenu:self.enclosingMenuItem.menu]; }
- (void)mouseExited:(NSEvent *)e { self.highlighted = NO; }
- (void)viewDidMoveToWindow { self.highlighted = NO; }

- (void)drawRect:(NSRect)r {
    if (!self.highlighted) return;
    [NSColor.selectedContentBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 5, 0) xRadius:4 yRadius:4] fill];
}

- (void)mouseUp:(NSEvent *)e {
    if (_enabled && _action) _action(self);
}

@end

#pragma mark - now playing

@implementation BABNowPlayingView {
    NSTextField *_title, *_subtitle;
    NSButton *_play;
    void (^_prev)(void), (^_toggle)(void), (^_next)(void);
}

- (NSButton *)button:(NSString *)sym size:(CGFloat)size action:(SEL)sel tip:(NSString *)tip {
    NSButton *b = [NSButton buttonWithImage:symbol(sym, size, NSFontWeightRegular) target:self action:sel];
    b.bordered = NO;
    b.contentTintColor = NSColor.labelColor;
    b.toolTip = tip;
    return b;
}

- (instancetype)initWithPrevious:(void (^)(void))previous playPause:(void (^)(void))playPause next:(void (^)(void))next {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kBABMenuWidth, 96)])) {
        _prev = [previous copy]; _toggle = [playPause copy]; _next = [next copy];

        NSView *art = [[NSView alloc] initWithFrame:NSMakeRect(16, 50, 38, 38)];
        art.wantsLayer = YES;
        art.layer.cornerRadius = 7;
        art.layer.backgroundColor = NSColor.quaternaryLabelColor.CGColor;
        NSImageView *note = [NSImageView imageViewWithImage:symbol(@"music.note", 17, NSFontWeightMedium)];
        note.contentTintColor = NSColor.secondaryLabelColor;
        note.frame = art.bounds;
        [art addSubview:note];
        [self addSubview:art];

        _title = label(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
        _title.frame = NSMakeRect(64, 69, kBABMenuWidth - 80, 17);
        [self addSubview:_title];
        _subtitle = label(@"", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
        _subtitle.frame = NSMakeRect(64, 52, kBABMenuWidth - 80, 15);
        [self addSubview:_subtitle];

        CGFloat mid = kBABMenuWidth / 2;
        NSButton *prev = [self button:@"backward.fill" size:15 action:@selector(prevClicked) tip:@"Previous"];
        prev.frame = NSMakeRect(mid - 76, 10, 36, 30);
        _play = [self button:@"play.fill" size:22 action:@selector(playClicked) tip:@"Play/Pause"];
        _play.frame = NSMakeRect(mid - 20, 8, 40, 34);
        NSButton *next = [self button:@"forward.fill" size:15 action:@selector(nextClicked) tip:@"Next"];
        next.frame = NSMakeRect(mid + 40, 10, 36, 30);
        [self addSubview:prev]; [self addSubview:_play]; [self addSubview:next];
    }
    return self;
}

- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle playing:(BOOL)playing {
    _title.stringValue = title ?: @"";
    _title.toolTip = title;
    _subtitle.stringValue = subtitle ?: @"";
    _subtitle.toolTip = subtitle;
    _play.image = symbol(playing ? @"pause.fill" : @"play.fill", 22, NSFontWeightRegular);
}

- (void)prevClicked { if (_prev) _prev(); }
- (void)playClicked { if (_toggle) _toggle(); }
- (void)nextClicked { if (_next) _next(); }

@end

#pragma mark - volume

@implementation BABVolumeView {
    NSSlider *_slider;
    void (^_action)(float);
    BOOL _dragging;
}

- (instancetype)initWithValue:(float)value action:(void (^)(float))action {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kBABMenuWidth, 28)])) {
        _action = [action copy];
        NSImageView *lo = [NSImageView imageViewWithImage:symbol(@"speaker.fill", 11, NSFontWeightRegular)];
        lo.contentTintColor = NSColor.secondaryLabelColor;
        lo.frame = NSMakeRect(14, 6, 16, 16);
        NSImageView *hi = [NSImageView imageViewWithImage:symbol(@"speaker.wave.3.fill", 11, NSFontWeightRegular)];
        hi.contentTintColor = NSColor.secondaryLabelColor;
        hi.frame = NSMakeRect(kBABMenuWidth - 34, 6, 22, 16);
        _slider = [NSSlider sliderWithValue:value minValue:0 maxValue:1 target:self action:@selector(changed:)];
        _slider.frame = NSMakeRect(34, 4, kBABMenuWidth - 72, 20);
        _slider.continuous = YES;
        [self addSubview:lo]; [self addSubview:_slider]; [self addSubview:hi];
    }
    return self;
}

- (void)changed:(NSSlider *)s {
    NSEvent *e = NSApp.currentEvent;
    _dragging = e.type == NSEventTypeLeftMouseDragged || e.type == NSEventTypeLeftMouseDown;
    if (_action) _action(s.floatValue);
}

- (void)setValue:(float)value {
    if (_dragging && (NSEvent.pressedMouseButtons & 1)) return;
    _dragging = NO;
    _slider.floatValue = value;
}

@end
