#import "AACPlayer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <os/lock.h>
#include <math.h>

#import "Log.h"

static const int kQueueBuffers = 3;
// Must leave a clear margin over the output device's I/O cycle (10.7 ms on 48 kHz USB/DisplayPort
// devices): 3 x 256 frames starved those devices while still being fine on the 5.3 ms built-in speakers.
static const UInt32 kQueueBufferFrames = 512;   // ~11.6 ms at 44.1 kHz
static const double kCatchUpThresholdMs = 350;  // skip back to target when this much extra audio is queued
enum { kFadeFrames = 256 };                     // ~5.8 ms: fades and crossfades that keep cuts from clicking
static const size_t kRunoutMarginFrames = 64;   // leave enough audio to fade out when a stall drains the buffer

typedef struct {
    const uint8_t *data;
    UInt32 len;
    AudioStreamPacketDescription desc;
    BOOL consumed;
} InputPacket;

@implementation AACPlayer {
    AudioConverterRef _conv;
    AudioQueueRef _queue;
    int _channels, _rate;
    float *_ring;              // interleaved float samples
    size_t _ringCap, _ringRead, _ringFill;   // in samples (frames * channels)
    os_unfair_lock _lock;
    BOOL _prebuffering;
    double _sumSq; uint64_t _sumN;
    double _smoothedFillMs, _readFrac, _deviceLatencyMs;
    uint64_t _callbacksSinceUnderrun;
    uint64_t _callbacksSinceStart;   // since creation / flush: start-of-stream grace period
    float _prev[8];                  // last consumed frame (x[-1] for the cubic interpolator)
}

static double deviceLatencyMs(NSString *uid);

+ (NSArray<NSDictionary *> *)outputDevices {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 sz = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz);
    UInt32 n = sz / sizeof(AudioDeviceID);
    AudioDeviceID ids[n ? n : 1];
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    NSMutableArray *out = [NSMutableArray array];
    for (UInt32 i = 0; i < n; i++) {
        AudioObjectPropertyAddress s = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                                        kAudioObjectPropertyElementMain};
        UInt32 ssz = 0;
        AudioObjectGetPropertyDataSize(ids[i], &s, 0, NULL, &ssz);
        if (ssz == 0) continue;  // no output streams
        CFStringRef name = NULL, uid = NULL;
        UInt32 csz = sizeof(CFStringRef);
        AudioObjectPropertyAddress pn = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectPropertyAddress pu = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(ids[i], &pn, 0, NULL, &csz, &name);
        csz = sizeof(CFStringRef);
        AudioObjectGetPropertyData(ids[i], &pu, 0, NULL, &csz, &uid);
        [out addObject:@{@"name": (__bridge_transfer NSString *)name ?: @"?",
                         @"uid": (__bridge_transfer NSString *)uid ?: @"?"}];
    }
    return out;
}

- (instancetype)initWithSampleRate:(int)sampleRate channels:(int)channels asc:(const uint8_t *)asc
                         deviceUID:(NSString *)deviceUID playback:(BOOL)playback {
    if (!(self = [super init])) return nil;
    _rate = sampleRate; _channels = channels;
    _volume = 1.0f;
    _targetLatencyMs = 200; _minTargetMs = 120; _maxTargetMs = 300; _maxLatencyMs = 1000; _playbackRatio = 1.0;
    _lock = OS_UNFAIR_LOCK_INIT;
    _ringCap = (size_t)sampleRate * channels * 2;   // 2 s
    _ring = calloc(_ringCap, sizeof(float));
    _prebuffering = YES;

    AudioStreamBasicDescription in = {0};
    in.mSampleRate = sampleRate;
    in.mFormatID = kAudioFormatMPEG4AAC;
    in.mFormatFlags = kMPEG4Object_AAC_LC;
    in.mFramesPerPacket = 1024;
    in.mChannelsPerFrame = (UInt32)channels;

    AudioStreamBasicDescription pcm = {0};
    pcm.mSampleRate = sampleRate;
    pcm.mFormatID = kAudioFormatLinearPCM;
    pcm.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    pcm.mChannelsPerFrame = (UInt32)channels;
    pcm.mBitsPerChannel = 32;
    pcm.mFramesPerPacket = 1;
    pcm.mBytesPerFrame = pcm.mBytesPerPacket = 4 * (UInt32)channels;

    OSStatus st = noErr;
    _decoderDelayFrames = 1024;
    if (asc) {   // AAC; without an ASC the caller decodes itself and hands over PCM (SBC)
        st = AudioConverterNew(&in, &pcm, &_conv);
        if (st) { BABLog(@"AudioConverterNew failed %d", (int)st); return nil; }
        st = AudioConverterSetProperty(_conv, kAudioConverterDecompressionMagicCookie, 2, asc);
        BABLog(@"AAC decoder ready (%d Hz, %d ch, ASC %02x %02x, cookie status %d)", sampleRate, channels, asc[0], asc[1], (int)st);
    } else {
        _decoderDelayFrames = 128;
        BABLog(@"PCM input ready (%d Hz, %d ch)", sampleRate, channels);
    }

    if (playback) {
        st = AudioQueueNewOutput(&pcm, queueCallback, (__bridge void *)self, NULL, NULL, 0, &_queue);
        if (st) { BABLog(@"AudioQueueNewOutput failed %d", (int)st); return nil; }
        if (deviceUID.length) {
            CFStringRef uid = (__bridge CFStringRef)deviceUID;
            st = AudioQueueSetProperty(_queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof uid);
            BABLog(@"Output device %@ -> status %d", deviceUID, (int)st);
        }
        for (int i = 0; i < kQueueBuffers; i++) {
            AudioQueueBufferRef buf;
            AudioQueueAllocateBuffer(_queue, kQueueBufferFrames * pcm.mBytesPerFrame, &buf);
            [self fill:buf];
            AudioQueueEnqueueBuffer(_queue, buf, 0, NULL);
        }
        _deviceLatencyMs = deviceLatencyMs(deviceUID);
        BABLog(@"Output device latency %.1f ms", _deviceLatencyMs);
        st = AudioQueueStart(_queue, NULL);
        BABLog(@"Audio output started (status %d), target buffer %.0f ms", (int)st, _targetLatencyMs);
    }
    return self;
}

static OSStatus inputProc(AudioConverterRef c, UInt32 *ioNum, AudioBufferList *io,
                          AudioStreamPacketDescription **outDesc, void *ud) {
    InputPacket *p = ud;
    if (p->consumed) { *ioNum = 0; return 1; }   // "no more data for now"
    io->mBuffers[0].mData = (void *)p->data;
    io->mBuffers[0].mDataByteSize = p->len;
    io->mBuffers[0].mNumberChannels = 0;
    p->desc = (AudioStreamPacketDescription){0, 0, p->len};
    if (outDesc) *outDesc = &p->desc;
    *ioNum = 1;
    p->consumed = YES;
    return noErr;
}

- (BOOL)decodeFrame:(const uint8_t *)data length:(size_t)len {
    if (!_conv) return NO;
    float pcm[2048 * 8];
    InputPacket p = {data, (UInt32)len, {0}, NO};
    UInt32 frames = 1024;
    AudioBufferList abl = {1, {{(UInt32)_channels, (UInt32)(frames * 4 * _channels), pcm}}};
    OSStatus st = AudioConverterFillComplexBuffer(_conv, inputProc, &p, &frames, &abl, NULL);
    if (st != noErr && st != 1) { _decodeErrors++; return NO; }
    if (frames == 0) return YES;   // decoder priming
    _framesDecoded++;
    [self pushPCM:pcm frames:frames];
    return YES;
}

- (void)pushPCM:(const float *)pcm frames:(size_t)frames {
    size_t n = frames * (size_t)_channels;
    double sq = 0;
    for (size_t i = 0; i < n; i++) sq += pcm[i] * pcm[i];
    os_unfair_lock_lock(&_lock);
    _sumSq += sq; _sumN += n;
    for (size_t i = 0; i < n; i++) {
        if (_ringFill == _ringCap) { _ringRead = (_ringRead + 1) % _ringCap; _ringFill--; _droppedSamples++; }
        _ring[(_ringRead + _ringFill) % _ringCap] = pcm[i];
        _ringFill++;
    }
    // Emergency only: a huge backlog (e.g. after a long radio stall) is cut back to the target.
    // Normal bursts and clock drift are absorbed by the playback-rate control in -fill:.
    size_t maxFill = (size_t)(_maxLatencyMs / 1000.0 * _rate) * _channels;
    size_t target = (size_t)(_targetLatencyMs / 1000.0 * _rate) * _channels;
    if (_ringFill > maxFill) {
        size_t drop = _ringFill - target;
        drop -= drop % _channels;
        _ringRead = (_ringRead + drop) % _ringCap; _ringFill -= drop; _droppedSamples += drop;
        _smoothedFillMs = _targetLatencyMs;
    }
    os_unfair_lock_unlock(&_lock);
}

// Pulls one queue buffer from the ring. While playing, the read speed is nudged by up to ±1%
// (4-point cubic Hermite interpolation) so the buffer level converges to the target: this absorbs
// bursts and the clock difference between the Fire TV and this Mac without dropping audio.
static inline float hermite(float xm1, float x0, float x1, float x2, float t) {
    float c1 = 0.5f * (x1 - xm1);
    float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

- (void)resetHistory {   // x[-1] := first queued frame (no discontinuity after a jump)
    for (int c = 0; c < _channels && c < 8; c++) _prev[c] = _ringFill ? _ring[(_ringRead + c) % _ringCap] : 0;
}
- (void)fill:(AudioQueueBufferRef)buf {
    [self render:buf->mAudioData];
    buf->mAudioDataByteSize = (UInt32)(kQueueBufferFrames * (size_t)_channels * sizeof(float));
}

// Renders kQueueBufferFrames interleaved frames into out.
- (void)render:(float *)out {
    const size_t ch = (size_t)_channels;
    const size_t wantFrames = kQueueBufferFrames;
    size_t written = 0;
    os_unfair_lock_lock(&_lock);
    _callbacksSinceStart++;
    size_t availFrames = _ringFill / ch;
    double fillMs = availFrames * 1000.0 / _rate;
    size_t targetFrames = (size_t)(_targetLatencyMs / 1000.0 * _rate);
    BOOL fadeIn = NO, fadeOut = NO;
    float oldAudio[kFadeFrames * 8];   // audio being skipped, crossfaded into the new position
    size_t oldFrames = 0;
    if (_prebuffering && availFrames >= targetFrames) {
        _prebuffering = NO; _smoothedFillMs = fillMs; _readFrac = 0;
        [self resetHistory];
        fadeIn = YES;
    }
    if (!_prebuffering && fillMs > _targetLatencyMs + kCatchUpThresholdMs) {
        // A radio stall just delivered a burst: rather than playing late audio for the next minute,
        // skip straight back to the target, crossfading so the jump doesn't click.
        if (!fadeIn && ch <= 8) {
            oldFrames = MIN(kFadeFrames, availFrames);
            for (size_t i = 0; i < oldFrames * ch; i++) oldAudio[i] = _ring[(_ringRead + i) % _ringCap];
        }
        size_t skip = availFrames - targetFrames;
        _ringRead = (_ringRead + skip * ch) % _ringCap;
        _ringFill -= skip * ch;
        _droppedSamples += skip * ch;
        _catchUps++;
        availFrames = targetFrames;
        fillMs = _smoothedFillMs = _targetLatencyMs;
        _readFrac = 0;
        [self resetHistory];
    }
    if (!_prebuffering) {
        _smoothedFillMs += 0.02 * (fillMs - _smoothedFillMs);
        double err = (_smoothedFillMs - _targetLatencyMs) / _targetLatencyMs;   // e.g. +0.5 = 50% over
        // ±1% normally; up to +2% when more than twice the target is queued (start-of-stream bursts)
        double maxUp = err > 1.0 ? 0.02 : 0.01;
        double ratio = 1.0 + fmax(-0.01, fmin(maxUp, err * 0.02));
        _playbackRatio = ratio;
        // About to run dry: end this buffer with a fade-out while there's still audio left for one.
        BOOL runningOut = availFrames < wantFrames + kRunoutMarginFrames;
        double pos = _readFrac;
#define RING(i, c) _ring[(_ringRead + (i) * ch + (c)) % _ringCap]
        for (; written < wantFrames; written++) {
            size_t i0 = (size_t)pos;
            if (i0 + 2 >= availFrames) break;               // need x0..x2 (x[-1] may be history)
            float t = (float)(pos - i0);
            for (size_t c = 0; c < ch; c++) {
                float xm1 = i0 == 0 ? _prev[c] : RING(i0 - 1, c);
                out[written * ch + c] = hermite(xm1, RING(i0, c), RING(i0 + 1, c), RING(i0 + 2, c), t);
            }
            pos += ratio;
        }
        size_t consumed = MIN((size_t)pos, availFrames);
        if (consumed > 0)
            for (size_t c = 0; c < ch && c < 8; c++) _prev[c] = RING(consumed - 1, c);
#undef RING
        _readFrac = pos - (double)(size_t)pos;
        _ringRead = (_ringRead + consumed * ch) % _ringCap;
        _ringFill -= consumed * ch;
        if (written < wantFrames || runningOut) {
            _underruns++; _prebuffering = YES; _callbacksSinceUnderrun = 0;
            fadeOut = YES;
            // Adaptive jitter buffer: every underrun buys more headroom (delay reports keep A/V sync).
            // The first 3 s of a stream are exempt: sources start with an irregular burst.
            if (_callbacksSinceStart > (uint64_t)(3.0 * _rate / kQueueBufferFrames))
                _targetLatencyMs = fmin(_maxTargetMs, _targetLatencyMs + 40);
        } else if (++_callbacksSinceUnderrun % (uint64_t)(5.0 * _rate / kQueueBufferFrames) == 0) {
            _targetLatencyMs = fmax(_minTargetMs, _targetLatencyMs - 10);   // 5 s clean: shrink
        }
    }
    os_unfair_lock_unlock(&_lock);
    if (oldFrames) {
        size_t n = MIN(oldFrames, written);
        for (size_t i = 0; i < n; i++) {
            float g = (float)i / (float)n;
            for (size_t c = 0; c < ch; c++) out[i * ch + c] = oldAudio[i * ch + c] * (1 - g) + out[i * ch + c] * g;
        }
    } else if (fadeIn) {
        size_t n = MIN(kFadeFrames, written);
        for (size_t i = 0; i < n; i++) {
            float g = (float)i / (float)n;
            for (size_t c = 0; c < ch; c++) out[i * ch + c] *= g;
        }
    }
    if (fadeOut) {
        size_t n = MIN(kFadeFrames, written);
        for (size_t i = 0; i < n; i++) {
            float g = (float)(n - 1 - i) / (float)n;
            for (size_t c = 0; c < ch; c++) out[(written - n + i) * ch + c] *= g;
        }
    }
    for (size_t i = written * ch; i < wantFrames * ch; i++) out[i] = 0;
}

#ifdef BAB_TESTS
- (void)testPushPCM:(const float *)pcm frames:(size_t)frames {
    os_unfair_lock_lock(&_lock);
    for (size_t i = 0; i < frames * _channels; i++) { _ring[(_ringRead + _ringFill) % _ringCap] = pcm[i]; _ringFill++; }
    os_unfair_lock_unlock(&_lock);
}
- (size_t)testRender:(float *)out {
    [self render:out];
    return kQueueBufferFrames;
}
#endif

- (void)flush {
    os_unfair_lock_lock(&_lock);
    _ringRead = 0; _ringFill = 0; _readFrac = 0; _prebuffering = YES; _callbacksSinceStart = 0;
    memset(_prev, 0, sizeof _prev);
    os_unfair_lock_unlock(&_lock);
}

// Everything between a frame arriving and it reaching the speaker: jitter buffer + one AAC frame of
// decoder delay + queue buffers + the output device's own latency.
- (double)estimatedOutputDelayMs {
    double buffer = _prebuffering ? _targetLatencyMs : _smoothedFillMs;
    double queue = kQueueBuffers * kQueueBufferFrames * 1000.0 / _rate;
    double decoder = _decoderDelayFrames * 1000.0 / _rate;
    return buffer + queue + decoder + _deviceLatencyMs;
}

static double deviceLatencyMs(NSString *uid) {
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof dev;
    if (uid.length) {
        CFStringRef u = (__bridge CFStringRef)uid;
        AudioValueTranslation t = {&u, sizeof u, &dev, sizeof dev};
        AudioObjectPropertyAddress a = {kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        sz = sizeof t;
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &t);
    } else {
        AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, &dev);
    }
    if (dev == kAudioObjectUnknown) return 0;
    UInt32 frames = 0, total = 0;
    Float64 rate = 44100;
    sz = sizeof rate;
    AudioObjectPropertyAddress r = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(dev, &r, 0, NULL, &sz, &rate);
    AudioObjectPropertySelector sels[] = {kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize};
    for (int i = 0; i < 3; i++) {
        AudioObjectPropertyAddress a = {sels[i], kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        sz = sizeof frames; frames = 0;
        if (AudioObjectGetPropertyData(dev, &a, 0, NULL, &sz, &frames) == noErr) total += frames;
    }
    // first output stream's latency
    AudioObjectPropertyAddress s = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    AudioStreamID streams[8]; sz = sizeof streams;
    if (AudioObjectGetPropertyData(dev, &s, 0, NULL, &sz, streams) == noErr && sz >= sizeof(AudioStreamID)) {
        AudioObjectPropertyAddress l = {kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        sz = sizeof frames; frames = 0;
        if (AudioObjectGetPropertyData(streams[0], &l, 0, NULL, &sz, &frames) == noErr) total += frames;
    }
    return rate > 0 ? total * 1000.0 / rate : 0;
}

static void queueCallback(void *ud, AudioQueueRef q, AudioQueueBufferRef buf) {
    AACPlayer *self = (__bridge AACPlayer *)ud;
    [self fill:buf];
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

- (double)bufferedMs {
    os_unfair_lock_lock(&_lock);
    double ms = _ringFill / (double)_channels / _rate * 1000.0;
    os_unfair_lock_unlock(&_lock);
    return ms;
}

- (double)rmsSinceLastQuery {
    os_unfair_lock_lock(&_lock);
    double r = _sumN ? sqrt(_sumSq / _sumN) : 0;
    _sumSq = 0; _sumN = 0;
    os_unfair_lock_unlock(&_lock);
    return r;
}

- (void)setVolume:(float)volume {
    _volume = volume;
    if (_queue) AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, volume);
}

- (void)stop {
    if (_queue) { AudioQueueStop(_queue, true); AudioQueueDispose(_queue, true); _queue = NULL; }
    if (_conv) { AudioConverterDispose(_conv); _conv = NULL; }
}

- (void)dealloc { [self stop]; free(_ring); }
@end
