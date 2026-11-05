// AAC access units in -> PCM out to a Core Audio output device, through an adaptive jitter buffer
// with ±1% playback-rate control (absorbs bursts and clock drift without dropping audio).
#import <Foundation/Foundation.h>

@interface AACPlayer : NSObject
// deviceUID nil = system default output. playback NO = decode only (for offline tests).
- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels asc:(const uint8_t *)asc
                         deviceUID:(NSString *)deviceUID playback:(BOOL)playback;
- (BOOL)decodeFrame:(const uint8_t *)data length:(size_t)len;
- (void)stop;
- (void)flush;                                  // drop buffered audio (stream suspended)
- (double)bufferedMs;
- (double)estimatedOutputDelayMs;               // arrival -> speaker, for AVDTP delay reports
@property(readonly) uint64_t framesDecoded, decodeErrors, underruns, droppedSamples, catchUps;
@property(readonly) double rmsSinceLastQuery;   // read-and-reset loudness of decoded audio (0..1)
@property double targetLatencyMs;               // jitter buffer level to hold (adaptive)
@property double minTargetMs, maxTargetMs;      // adaptive range: +40 ms per underrun, -10 ms per clean 5 s (default 120-300, starts at 200)
@property double maxLatencyMs;                  // emergency: beyond this, drop audio back to target, default 1000
@property(readonly) double playbackRatio;       // current rate correction (1.0 = nominal)
@property(nonatomic) float volume;              // 0..1, applied to the output queue
+ (NSArray<NSDictionary *> *)outputDevices;     // [{name, uid}]
@end
