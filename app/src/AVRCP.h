// AVRCP over one L2CAP channel (PSM 0x17) to the audio source.
// As controller: play/pause/next/previous, and the current title from the source's player.
// As target: answers absolute-volume requests, if a source sends them (Android decides that from
// the Mac's own SDP record, which we can't change, so most won't).
#import <Foundation/Foundation.h>
@class CBL2CAPChannel, BABAVRCP;

typedef NS_ENUM(uint8_t, BABAVRCPKey) {
    BABAVRCPKeyPlay = 0x44, BABAVRCPKeyStop = 0x45, BABAVRCPKeyPause = 0x46,
    BABAVRCPKeyNext = 0x4B, BABAVRCPKeyPrevious = 0x4C,
};

typedef NS_ENUM(int, BABPlayStatus) { BABPlayStatusUnknown = -1, BABPlayStatusStopped = 0, BABPlayStatusPlaying = 1, BABPlayStatusPaused = 2 };

@protocol BABAVRCPDelegate <NSObject>
- (void)avrcpDidUpdateMedia:(BABAVRCP *)avrcp;                   // title or play status changed
@optional
- (void)avrcp:(BABAVRCP *)avrcp didSetVolume:(float)volume;      // source sent an absolute volume (0..1)
- (void)avrcpDidClose:(BABAVRCP *)avrcp;
@end

@interface BABAVRCP : NSObject
- (instancetype)initWithChannel:(CBL2CAPChannel *)channel;   // runs on the main run loop
@property(weak) id<BABAVRCPDelegate> delegate;
@property(readonly, copy) NSString *title, *artist, *album;
@property(readonly) BABPlayStatus playStatus;
@property(nonatomic) float volume;   // what we report as our absolute volume (0..1)
- (void)sendKey:(BABAVRCPKey)key;   // press + release
- (void)close;
@end
