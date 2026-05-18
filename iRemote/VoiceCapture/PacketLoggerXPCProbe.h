// Probes whether we can connect to bluetoothd's BTPacketLogger XPC mach
// service from a regular user-mode app. If yes, we have a no-sudo,
// no-helper, no-Additional-Tools path to live HCI traffic.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IRMPacketLoggerProbe : NSObject

- (instancetype)initWithLogger:(void (^)(NSString *line))logger;

/// Attempt a connection and a battery of probe messages to each
/// candidate XPC service. Logs every event/error. Non-blocking.
- (void)runProbe;

@end

NS_ASSUME_NONNULL_END
