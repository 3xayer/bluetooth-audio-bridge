#import "AACPlayer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <os/lock.h>
#include <math.h>

#import "Log.h"

static const int kQueueBuffers = 3;
static const UInt32 kQueueBufferFrames = 512;   // ~11.6 ms at 44.1 kHz

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
    _targetLatencyMs = 180; _minTargetMs = 180; _maxTargetMs = 450; _maxLatencyMs = 1000; _playbackRatio = 1.0;
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

    OSStatus st = AudioConverterNew(&in, &pcm, &_conv);
    if (st) { BABLog(@"AudioConverterNew failed %d", (int)st); return nil; }
    st = AudioConverterSetProperty(_conv, kAudioConverterDecompressionMagicCookie, 2, asc);
    BABLog(@"AAC decoder ready (%d Hz, %d ch, ASC %02x %02x, cookie status %d)", sampleRate, channels, asc[0], asc[1], (int)st);

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
    float pcm[2048 * 8];
    InputPacket p = {data, (UInt32)len, {0}, NO};
    UInt32 frames = 1024;
    AudioBufferList abl = {1, {{(UInt32)_channels, (UInt32)(frames * 4 * _channels), pcm}}};
    OSStatus st = AudioConverterFillComplexBuffer(_conv, inputProc, &p, &frames, &abl, NULL);
    if (st != noErr && st != 1) { _decodeErrors++; return NO; }
    if (frames == 0) return YES;   // decoder priming
    _framesDecoded++;
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
    return YES;
}

// Pulls one queue buffer from the ring. While playing, the read speed is nudged by up to ±1%
// (linear interpolation) so the buffer level converges to the target: this absorbs bursts and the
// clock difference between the Fire TV and this Mac without dropping audio.
- (void)fill:(AudioQueueBufferRef)buf {
    float *out = buf->mAudioData;
    const size_t ch = (size_t)_channels;
    const size_t wantFrames = kQueueBufferFrames;
    size_t written = 0;
    os_unfair_lock_lock(&_lock);
    _callbacksSinceStart++;
    size_t availFrames = _ringFill / ch;
    double fillMs = availFrames * 1000.0 / _rate;
    size_t targetFrames = (size_t)(_targetLatencyMs / 1000.0 * _rate);
    if (_prebuffering && availFrames >= targetFrames) { _prebuffering = NO; _smoothedFillMs = fillMs; _readFrac = 0; }
    if (!_prebuffering) {
        _smoothedFillMs += 0.02 * (fillMs - _smoothedFillMs);
        double err = (_smoothedFillMs - _targetLatencyMs) / _targetLatencyMs;   // e.g. +0.5 = 50% over
        // ±1% normally; up to +2% when more than twice the target is queued (start-of-stream bursts)
        double maxUp = err > 1.0 ? 0.02 : 0.01;
        double ratio = 1.0 + fmax(-0.01, fmin(maxUp, err * 0.02));
        _playbackRatio = ratio;
        double pos = _readFrac;
        for (; written < wantFrames; written++) {
            size_t i0 = (size_t)pos;
            if (i0 + 1 >= availFrames) break;               // need two frames to interpolate
            float f = (float)(pos - i0);
            for (size_t c = 0; c < ch; c++) {
                float a = _ring[(_ringRead + i0 * ch + c) % _ringCap];
                float b = _ring[(_ringRead + (i0 + 1) * ch + c) % _ringCap];
                out[written * ch + c] = a + (b - a) * f;
            }
            pos += ratio;
        }
        size_t consumed = MIN((size_t)pos, availFrames);
        _readFrac = pos - (double)(size_t)pos;
        _ringRead = (_ringRead + consumed * ch) % _ringCap;
        _ringFill -= consumed * ch;
        if (written < wantFrames) {
            _underruns++; _prebuffering = YES; _callbacksSinceUnderrun = 0;
            // Adaptive jitter buffer: every underrun buys more headroom (delay reports keep A/V sync).
            // The first 3 s of a stream are exempt: sources start with an irregular burst.
            if (_callbacksSinceStart > (uint64_t)(3.0 * _rate / kQueueBufferFrames))
                _targetLatencyMs = fmin(_maxTargetMs, _targetLatencyMs + 40);
        } else if (++_callbacksSinceUnderrun % (uint64_t)(20.0 * _rate / kQueueBufferFrames) == 0) {
            _targetLatencyMs = fmax(_minTargetMs, _targetLatencyMs - 10);   // 20 s clean: shrink slowly
        }
    }
    os_unfair_lock_unlock(&_lock);
    for (size_t i = written * ch; i < wantFrames * ch; i++) out[i] = 0;
    buf->mAudioDataByteSize = (UInt32)(wantFrames * ch * sizeof(float));
}

- (void)flush {
    os_unfair_lock_lock(&_lock);
    _ringRead = 0; _ringFill = 0; _readFrac = 0; _prebuffering = YES; _callbacksSinceStart = 0;
    os_unfair_lock_unlock(&_lock);
}

// Everything between a frame arriving and it reaching the speaker: jitter buffer + one AAC frame of
// decoder delay + queue buffers + the output device's own latency.
- (double)estimatedOutputDelayMs {
    double buffer = _prebuffering ? _targetLatencyMs : _smoothedFillMs;
    double queue = kQueueBuffers * kQueueBufferFrames * 1000.0 / _rate;
    double decoder = 1024 * 1000.0 / _rate;
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
