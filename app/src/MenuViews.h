// Custom menu item views. Clicking them doesn't close the menu, and they can change while it's open.
#import <Cocoa/Cocoa.h>

static const CGFloat kBABMenuWidth = 300;

typedef NS_ENUM(NSInteger, BABRowMark) { BABRowMarkNone, BABRowMarkCheck, BABRowMarkSpinner };

// A clickable row like a normal menu item, with a checkmark or a spinner in front.
@interface BABMenuRow : NSView
- (instancetype)initWithTitle:(NSString *)title action:(void (^)(BABMenuRow *row))action;
@property(nonatomic) BABRowMark mark;
@property(copy) NSString *identifier2;   // e.g. the device address
@property(nonatomic) BOOL highlighted;
@property(nonatomic) BOOL enabled;                      // NO: greyed out, ignores clicks
@property(copy) BABRowMark (^markProvider)(void);       // optional: evaluated by -refresh
@property(copy) BOOL (^enabledProvider)(void);          // optional: evaluated by -refresh
- (void)refresh;
+ (void)highlightItem:(NSMenuItem *)item inMenu:(NSMenu *)menu;   // call from menu:willHighlightItem:
@end

// Title, artist and transport buttons of the source's player.
@interface BABNowPlayingView : NSView
- (instancetype)initWithPrevious:(void (^)(void))previous playPause:(void (^)(void))playPause next:(void (^)(void))next;
- (void)setTitle:(NSString *)title subtitle:(NSString *)subtitle playing:(BOOL)playing;
@end

// Volume slider spanning the menu width.
@interface BABVolumeView : NSView
- (instancetype)initWithValue:(float)value action:(void (^)(float value))action;
- (void)setValue:(float)value;   // ignored while the user drags the slider
@end
