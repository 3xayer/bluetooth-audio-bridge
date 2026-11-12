#import "SystemVolume.h"
#import "Log.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

@implementation BABSystemVolume {
    void (^_handler)(float);
    AudioDeviceID _device;
    AudioObjectPropertyListenerBlock _volumeListener, _defaultListener;
}

static const AudioObjectPropertyAddress kVirtualVolume = {
    kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
static const AudioObjectPropertyAddress kDefaultOutput = {
    kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

- (instancetype)initWithDeviceUID:(NSString *)uid changeHandler:(void (^)(float))handler {
    if ((self = [super init])) {
        _handler = [handler copy];
        __weak BABSystemVolume *ws = self;
        _volumeListener = ^(UInt32 n, const AudioObjectPropertyAddress *a) { [ws notify]; };
        _defaultListener = ^(UInt32 n, const AudioObjectPropertyAddress *a) { [ws attach]; [ws notify]; };
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutput, dispatch_get_main_queue(), _defaultListener);
        _deviceUID = [uid copy];
        [self attach];
    }
    return self;
}

- (void)dealloc {
    [self detach];
    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &kDefaultOutput, dispatch_get_main_queue(), _defaultListener);
}

- (void)setDeviceUID:(NSString *)uid {
    _deviceUID = [uid copy];
    [self attach];
    [self notify];
}

- (AudioDeviceID)resolve {
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 sz = sizeof dev;
    if (_deviceUID.length) {
        CFStringRef u = (__bridge CFStringRef)_deviceUID;
        AudioObjectPropertyAddress a = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof u, &u, &sz, &dev);
    } else {
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &kDefaultOutput, 0, NULL, &sz, &dev);
    }
    return dev;
}

// Devices report volume on the main element, on channels 1/2, or both: listen to all of them.
- (void)forEachVolumeAddress:(void (^)(AudioObjectPropertyAddress))block {
    for (UInt32 el = 0; el <= 2; el++) block((AudioObjectPropertyAddress){kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el});
    block((AudioObjectPropertyAddress){kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain});
}

- (void)detach {
    if (_device == kAudioObjectUnknown) return;
    AudioDeviceID dev = _device;
    AudioObjectPropertyListenerBlock l = _volumeListener;
    [self forEachVolumeAddress:^(AudioObjectPropertyAddress a) {
        if (AudioObjectHasProperty(dev, &a)) AudioObjectRemovePropertyListenerBlock(dev, &a, dispatch_get_main_queue(), l);
    }];
    _device = kAudioObjectUnknown;
}

- (void)attach {
    AudioDeviceID dev = [self resolve];
    if (dev == _device) return;
    [self detach];
    _device = dev;
    if (dev == kAudioObjectUnknown) return;
    AudioObjectPropertyListenerBlock l = _volumeListener;
    [self forEachVolumeAddress:^(AudioObjectPropertyAddress a) {
        if (AudioObjectHasProperty(dev, &a)) AudioObjectAddPropertyListenerBlock(dev, &a, dispatch_get_main_queue(), l);
    }];
    BABLog(@"Mac volume control: device %u, settable %d, volume %.2f", dev, self.settable, self.volume);
}

- (void)notify {
    float v = self.volume;
    if (_handler && !isnan(v)) _handler(v);
}

- (BOOL)settable {
    if (_device == kAudioObjectUnknown || !AudioObjectHasProperty(_device, &kVirtualVolume)) return NO;
    Boolean ok = false;
    return AudioObjectIsPropertySettable(_device, &kVirtualVolume, &ok) == noErr && ok;
}

- (float)volume {
    if (_device == kAudioObjectUnknown || !AudioObjectHasProperty(_device, &kVirtualVolume)) return NAN;
    Float32 v = 0;
    UInt32 sz = sizeof v;
    if (AudioObjectGetPropertyData(_device, &kVirtualVolume, 0, NULL, &sz, &v) != noErr) return NAN;
    return v;
}

- (void)setVolume:(float)volume {
    if (!self.settable) return;
    Float32 v = fminf(fmaxf(volume, 0), 1);
    AudioObjectSetPropertyData(_device, &kVirtualVolume, 0, NULL, sizeof v, &v);
    if (v > 0) {   // turning the volume up from the source should be heard: unmute
        UInt32 mute = 0;
        AudioObjectPropertyAddress m = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        if (AudioObjectHasProperty(_device, &m)) AudioObjectSetPropertyData(_device, &m, 0, NULL, sizeof mute, &mute);
    }
}

@end
