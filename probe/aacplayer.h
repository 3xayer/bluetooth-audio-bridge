// AAC access units in -> PCM out to a Core Audio output device, through a small jitter buffer.
#import <Foundation/Foundation.h>

@interface AACPlayer : NSObject
// deviceUID nil = system default output. playback NO = decode only (for offline tests).
- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels asc:(const uint8_t *)asc
                         deviceUID:(NSString *)deviceUID playback:(BOOL)playback;
- (BOOL)decodeFrame:(const uint8_t *)data length:(size_t)len;
- (void)stop;
- (double)bufferedMs;
@property(readonly) uint64_t framesDecoded, decodeErrors, underruns, droppedSamples;
@property(readonly) double rmsSinceLastQuery;   // read-and-reset loudness of decoded audio (0..1)
@property double targetLatencyMs;               // jitter buffer level to hold (via ±1% rate control), default 180
@property double minTargetMs, maxTargetMs;       // adaptive target range: +40 ms per underrun, -10 ms per clean 20 s
@property double maxLatencyMs;                  // emergency: beyond this, drop audio back to target, default 1000
@property(readonly) double playbackRatio;       // current rate correction (1.0 = nominal)
- (double)estimatedOutputDelayMs;               // arrival -> speaker, for AVDTP delay reports
- (void)flush;                                  // drop buffered audio (stream suspended)
+ (NSArray<NSDictionary *> *)outputDevices;     // [{name, uid}]
@end
