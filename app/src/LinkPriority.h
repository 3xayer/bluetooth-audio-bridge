#import <Foundation/Foundation.h>

// Gives the Bluetooth link to the audio source priority in the controller's scheduler, so BLE scans
// (AirPods automatic switching, Nearby) and device searches don't starve the incoming audio.
@interface BABLinkPriority : NSObject
+ (instancetype)shared;
- (void)enableForPeer:(NSUUID *)peer;   // idempotent; refreshed periodically while enabled
- (void)disable;
@end
