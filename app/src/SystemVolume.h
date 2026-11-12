// The volume of a Mac output device (what the menu bar volume and the keyboard's volume keys change).
#import <Foundation/Foundation.h>

@interface BABSystemVolume : NSObject
// uid nil = follow the system default output. The handler runs on the main queue whenever the
// volume changes (from anywhere, including -setVolume:).
- (instancetype)initWithDeviceUID:(NSString *)uid changeHandler:(void (^)(float volume))handler;
@property(nonatomic, copy) NSString *deviceUID;
@property(nonatomic) float volume;              // 0..1; reads NAN if the device has no volume control
@property(readonly) BOOL settable;              // the device has a volume macOS can change
@end
