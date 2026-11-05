#import <Foundation/Foundation.h>

// Logs to NSLog and to ~/Library/Logs/Bluetooth Audio Bridge.log (rotated at 5 MB).
void BABLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *BABLogPath(void);
