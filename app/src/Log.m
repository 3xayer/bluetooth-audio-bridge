#import "Log.h"
#include <unistd.h>

NSString *BABLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Bluetooth Audio Bridge.log"];
}

void BABLog(NSString *fmt, ...) {
    static dispatch_queue_t q;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("bab.log", DISPATCH_QUEUE_SERIAL);
        df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    va_list a;
    va_start(a, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    int pid = getpid();
    NSDate *now = [NSDate date];
    dispatch_async(q, ^{
        NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [df stringFromDate:now], pid, msg];
        NSString *path = BABLogPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
        if ([attr fileSize] > 5 * 1024 * 1024) {
            NSString *old = [path stringByAppendingString:@".1"];
            [fm removeItemAtPath:old error:nil];
            [fm moveItemAtPath:path toPath:old error:nil];
        }
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    });
#ifdef DEBUG
    NSLog(@"%@", msg);
#endif
}
