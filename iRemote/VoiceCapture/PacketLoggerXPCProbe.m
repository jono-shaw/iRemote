#import "PacketLoggerXPCProbe.h"
#import <xpc/xpc.h>

// Service names + key/command names harvested from `bluetoothd` strings:
//   com.apple.bluetooth.BTPacketLogger
//   com.apple.bluetooth.BTPacketLogger.ios
//   com.apple.PacketLogger.HCI
//   PacketLogger.Authorization
//   PacketLogger.HCI
//   keys we'll try: action / command / event / subscribe / Enable / Disable / Start / Stop / CAPTURE / filter

@interface IRMPacketLoggerProbe ()
@property (nonatomic, copy)   void (^logger)(NSString *);
@property (nonatomic, strong) NSMutableArray *connections;  // keep connections alive
@end

@implementation IRMPacketLoggerProbe

- (instancetype)initWithLogger:(void (^)(NSString *))logger {
    if ((self = [super init])) {
        _logger = [logger copy];
        _connections = [NSMutableArray array];
    }
    return self;
}

- (void)log:(NSString *)s { if (_logger) _logger(s); }

- (NSString *)describeXPC:(xpc_object_t)obj {
    if (!obj) return @"(nil)";
    char *desc = xpc_copy_description(obj);
    NSString *out = [NSString stringWithUTF8String:desc ?: ""];
    free(desc);
    return [out length] > 200 ? [[out substringToIndex:200] stringByAppendingString:@"…"] : out;
}

- (void)runProbe {
    [self log:@"PacketLoggerXPCProbe: starting"];

    NSArray *services = @[
        @"com.apple.bluetooth.BTPacketLogger",
        @"com.apple.bluetooth.BTPacketLogger.ios",
        @"com.apple.PacketLogger.HCI",
    ];

    for (NSString *svc in services) {
        [self attemptConnect:svc];
    }

    // After 2s, try sending probe messages on the first successful connection
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{ [self sendProbeMessages]; });
}

- (void)attemptConnect:(NSString *)serviceName {
    dispatch_queue_t q = dispatch_queue_create("iRemote.xpc-probe", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t conn = xpc_connection_create_mach_service(
        serviceName.UTF8String,
        q,
        0  // 0 = client connection (not listener)
    );

    if (!conn) {
        [self log:[NSString stringWithFormat:@"  ✗ create conn FAILED for %@", serviceName]];
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSString *svcCopy = [serviceName copy];

    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        __strong typeof(self) self = weakSelf;
        if (!self) return;

        xpc_type_t t = xpc_get_type(event);
        if (t == XPC_TYPE_ERROR) {
            const char *desc = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
            NSString *errStr = desc ? @(desc) : @"?";
            // Map common error constants to symbolic names
            NSString *kind = @"err";
            if (event == XPC_ERROR_CONNECTION_INVALID)    kind = @"INVALID";
            else if (event == XPC_ERROR_CONNECTION_INTERRUPTED) kind = @"INTERRUPTED";
            else if (event == XPC_ERROR_TERMINATION_IMMINENT)   kind = @"TERMINATION";
            [self log:[NSString stringWithFormat:@"  [%@] %@: %@", svcCopy, kind, errStr]];
        } else if (t == XPC_TYPE_DICTIONARY) {
            [self log:[NSString stringWithFormat:@"  [%@] DICT: %@", svcCopy, [self describeXPC:event]]];
        } else if (t == XPC_TYPE_DATA) {
            size_t len = xpc_data_get_length(event);
            [self log:[NSString stringWithFormat:@"  [%@] DATA len=%zu", svcCopy, len]];
        } else {
            [self log:[NSString stringWithFormat:@"  [%@] type=%s desc=%@", svcCopy, xpc_type_get_name(t), [self describeXPC:event]]];
        }
    });

    xpc_connection_resume(conn);
    [self.connections addObject:conn];
    [self log:[NSString stringWithFormat:@"  → connected lazily to %@", serviceName]];
}

- (void)sendProbeMessages {
    [self log:@"sending probe messages…"];

    // Build a battery of candidate request shapes.
    NSArray<NSDictionary *> *shapes = @[
        @{ @"command": @"subscribe" },
        @{ @"command": @"start" },
        @{ @"command": @"start", @"channel": @"HCI" },
        @{ @"command": @"register", @"channel": @"PacketLogger.HCI" },
        @{ @"action": @"subscribe", @"channel": @"PacketLogger.HCI" },
        @{ @"action": @"start", @"type": @"hci" },
        @{ @"Enable": @YES },
        @{ @"CAPTURE": @"start" },
        @{ @"filter": @"hci", @"action": @"start" },
        @{ @"PacketLogger.HCI": @"start" },
    ];

    int idx = 0;
    for (xpc_connection_t conn in self.connections) {
        for (NSDictionary *shape in shapes) {
            xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
            for (NSString *key in shape) {
                id val = shape[key];
                if ([val isKindOfClass:[NSString class]]) {
                    xpc_dictionary_set_string(msg, key.UTF8String, [val UTF8String]);
                } else if ([val isKindOfClass:[NSNumber class]]) {
                    NSNumber *n = val;
                    if (strcmp([n objCType], @encode(BOOL)) == 0) {
                        xpc_dictionary_set_bool(msg, key.UTF8String, [n boolValue]);
                    } else {
                        xpc_dictionary_set_int64(msg, key.UTF8String, [n longLongValue]);
                    }
                }
            }
            xpc_connection_send_message(conn, msg);
            idx++;
        }
    }
    [self log:[NSString stringWithFormat:@"sent %d probe messages across %lu connections; watching for replies", idx, (unsigned long)self.connections.count]];
}

@end
