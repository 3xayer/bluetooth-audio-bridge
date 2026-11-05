// One A2DP sink connection to a paired source (e.g. a Fire TV), with the Mac as AVDTP initiator:
// open signaling -> discover -> configure AAC (+ delay reporting) -> open -> media transport,
// then decode and play whatever the source streams.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SinkState) {
    SinkStateIdle,
    SinkStateConnecting,   // paging / AVDTP setup in progress
    SinkStateReady,        // stream open; the source routes audio here but nothing is playing
    SinkStateStreaming,    // audio flowing
    SinkStateEnded,        // finished; see endReason / everConnected
};

@class SinkSession;
@protocol SinkSessionDelegate <NSObject>
- (void)sinkSessionDidChangeState:(SinkSession *)session;   // always called on the main thread
@end

@interface SinkSession : NSObject
- (instancetype)initWithAddress:(NSString *)address;
@property(weak) id<SinkSessionDelegate> delegate;
@property(nonatomic, readonly) SinkState state;
@property(readonly, copy) NSString *endReason;
@property(readonly) BOOL everConnected;        // reached Ready at least once
@property(readonly, copy) NSString *address;
@property(nonatomic, copy) NSString *outputDeviceUID;      // nil = system default; can change while running
@property(nonatomic) float volume;              // 0..1
// Live stats (updated every second).
@property(readonly) double bitrateKbps;
@property(readonly) double delayMs;
@property(readonly) uint64_t underruns, lostPackets;
@property(readonly, copy) NSString *codecDescription;

- (void)start;
- (void)stop;   // graceful AVDTP CLOSE, then tear down; ends with state Ended

// Internal helper-process role (bluetoothd allows one L2CAP channel per PSM per client, so the
// media channel is opened by a second process). Called from main() when launched with --transport.
+ (int)runTransportHelperWithAddress:(NSString *)address socketPath:(NSString *)path;
@end
