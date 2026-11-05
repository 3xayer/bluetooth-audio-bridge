// Exercises AACPlayer's jitter buffer + rate-controlled cubic resampler with synthetic sine waves.
// Build: see tests/run.sh
#import <Foundation/Foundation.h>
#import "AACPlayer.h"
#include <math.h>

@interface AACPlayer (Tests)
- (void)testPushPCM:(const float *)pcm frames:(size_t)frames;
- (size_t)testRender:(float *)out;
@end

void BABLog(NSString *fmt, ...) {}
NSString *BABLogPath(void) { return @""; }

static int fails;

// Feed a sine of `hz` with the buffer held above target so the resampler runs at ratio > 1, then
// check: no discontinuities (max step), and stable level (per-block RMS), skipping the start.
static void runSine(double hz, double maxStepFactor, double rmsTolerance) {
    const uint8_t asc[2] = {0x12, 0x10};
    AACPlayer *p = [[AACPlayer alloc] initWithSampleRate:44100 channels:2 asc:asc deviceUID:nil playback:NO];
    const double amp = 0.5, w = 2 * M_PI * hz / 44100.0;
    size_t t = 0;
    float in[1024 * 2], out[1024 * 2];
    double maxStep = 0, minRms = 1e9, maxRms = 0, last = NAN;
    int blocks = 0;
    for (int iter = 0; iter < 2000; iter++) {
        // real-time feed (1024 frames per 4 renders of 256) after an initial overfill to ~250 ms, so the
        // rate control runs above 1.0 and the cubic interpolator works at fractional positions
        size_t pushFrames = (iter % 4 == 0) ? 1024 : 0;
        if (iter < 11) pushFrames = 1024;
        for (size_t i = 0; i < pushFrames; i++, t++) {
            float v = (float)(amp * sin(w * t));
            in[2 * i] = v; in[2 * i + 1] = v;
        }
        if (pushFrames) [p testPushPCM:in frames:pushFrames];
        size_t n = [p testRender:out];
        if (iter < 20) { last = out[2 * (n - 1)]; continue; }   // skip the prebuffer start
        double sq = 0;
        for (size_t i = 0; i < n; i++) {
            double v = out[2 * i];
            if (!isnan(last)) maxStep = fmax(maxStep, fabs(v - last));
            last = v;
            sq += v * v;
        }
        double rms = sqrt(sq / n);
        if (rms > 0.01) { minRms = fmin(minRms, rms); maxRms = fmax(maxRms, rms); blocks++; }
    }
    double idealStep = amp * w * 1.02;   // max slope per sample at up to +2% speed
    double idealRms = amp / sqrt(2);
    BOOL ok = p.catchUps == 0 && p.underruns == 0 && maxStep <= idealStep * maxStepFactor && minRms >= idealRms * (1 - rmsTolerance) &&
              maxRms <= idealRms * (1 + rmsTolerance) && blocks > 100;
    printf("%s %5.0f Hz: max step %.4f (ideal %.4f), block RMS %.4f..%.4f (ideal %.4f), ratio %.4f, catch-ups %llu, underruns %llu\n",
           ok ? "ok  " : "FAIL", hz, maxStep, idealStep, minRms, maxRms, idealRms, p.playbackRatio, p.catchUps, p.underruns);
    if (!ok) fails++;
}

int main(void) {
    @autoreleasepool {
        runSine(1000, 1.05, 0.02);
        runSine(5000, 1.10, 0.03);
        // 4-point cubic worst case at 12 kHz (half-sample offset): 9/8 cos(w/2) - 1/8 cos(3w/2) = 0.843
        // = -1.5 dB (linear interpolation: cos(w/2) = 0.657 = -3.7 dB)
        runSine(12000, 1.25, 0.17);
        printf(fails ? "%d FAILED\n" : "all passed\n", fails);
    }
    return fails != 0;
}
