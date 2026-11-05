#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "SinkSession.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Internal helper role: opens the media transport channel and hands its socket to the app.
        if (argc >= 4 && !strcmp(argv[1], "--transport"))
            return [SinkSession runTransportHelperWithAddress:@(argv[2]) socketPath:@(argv[3])];

        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
