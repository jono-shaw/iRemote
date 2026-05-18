#import "PrivateBluetoothManager.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreAudio/CoreAudio.h>

// Forward declarations of private classes we duck-type onto NSObject.
// Methods we call on `id` values are dispatched dynamically; the @try/@catch
// in callers handles any "unrecognized selector" exceptions.
@interface NSObject (IRMPrivateBT)
+ (id)sharedInstance;
- (NSArray *)pairedDevices;
- (NSArray *)connectedDevices;
- (NSArray *)connectingDevices;
- (id)deviceFromAddressString:(NSString *)addr;
- (id)deviceFromIdentifier:(NSString *)ident;
- (BOOL)available;
- (BOOL)connected;
- (BOOL)powered;
- (BOOL)connectable;
- (BOOL)wasDeviceDiscovered:(id)dev;
- (NSString *)localAddress;
- (NSString *)address;
- (NSString *)name;
- (NSString *)productName;
- (BOOL)paired;
- (BOOL)isAppleAudioDevice;
- (NSInteger)productId;
- (NSInteger)vendorId;
- (NSInteger)majorClass;
- (NSInteger)minorClass;
- (NSInteger)micMode;
- (void)startVoiceCommand;
- (void)endVoiceCommand;
@end

static NSString *IRMStringValue(id value) {
    if (!value) return @"?";
    if ([value isKindOfClass:[NSString class]]) return value;
    return [value description] ?: @"?";
}

static NSArray *IRMArrayGetter(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) return nil;
    NSArray *(*send)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    id result = send(target, selector);
    return [result isKindOfClass:[NSArray class]] ? result : nil;
}

@implementation IRMVoiceCommander {
    IRMLogBlock _logger;
    Class _BMClass;
    id _bm; // BluetoothManager singleton
}

- (instancetype)initWithLogger:(IRMLogBlock)logger {
    if ((self = [super init])) {
        _logger = [logger copy];
    }
    return self;
}

- (void)log:(NSString *)s {
    if (_logger) _logger(s);
}

- (BOOL)loadAndAttach {
    void *h = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_NOW);
    if (!h) {
        [self log:[NSString stringWithFormat:@"dlopen FAILED: %s", dlerror() ?: "(no error)"]];
        return NO;
    }
    _BMClass = NSClassFromString(@"BluetoothManager");
    if (!_BMClass) {
        [self log:@"NSClassFromString(BluetoothManager) returned nil after dlopen"];
        return NO;
    }
    @try {
        _bm = [_BMClass performSelector:@selector(sharedInstance)];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"sharedInstance threw %@: %@", e.name, e.reason]];
        return NO;
    }
    if (!_bm) {
        [self log:@"sharedInstance returned nil"];
        return NO;
    }
    [self log:@"BluetoothManager attached"];
    return YES;
}

- (void)dumpPairedDevices {
    if (!_bm) return;

    // Manager-level state first
    @try {
        NSString *local = [_bm localAddress];
        BOOL avail = [_bm available];
        BOOL pwr = [_bm powered];
        BOOL conn = [_bm connected];
        [self log:[NSString stringWithFormat:@"BM state: local=%@ available=%d powered=%d connected=%d", local, avail, pwr, conn]];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"BM state probe threw: %@", e.reason]];
    }

    // pairedDevices, connectedDevices, connectingDevices — try all three
    for (NSString *list in @[@"pairedDevices", @"connectedDevices", @"connectingDevices"]) {
        NSArray *arr = nil;
        @try {
            arr = IRMArrayGetter(_bm, list);
        } @catch (NSException *e) {
            [self log:[NSString stringWithFormat:@"%@ threw: %@", list, e.reason]];
            continue;
        }
        [self log:[NSString stringWithFormat:@"%@.count = %lu", list, (unsigned long)arr.count]];
        for (id dev in arr) {
            NSString *name = @"?", *addr = @"?";
            BOOL conn = NO, paired = NO;
            @try { name = IRMStringValue([dev name]); } @catch (__unused id e) {}
            @try { addr = IRMStringValue([dev address]); } @catch (__unused id e) {}
            @try { conn = [dev connected]; } @catch (__unused id e) {}
            @try { paired = [dev paired]; } @catch (__unused id e) {}
            [self log:[NSString stringWithFormat:@"    · %@ %@ conn=%d paired=%d", name, addr, conn, paired]];
        }
    }

    // Try deviceFromIdentifier with the CoreBluetooth UUID (E15EA961-...)
    NSString *cbUUID = @"E15EA961-5539-07CA-513F-C51CBB06E0F6";
    @try {
        id viaIdent = [_bm deviceFromIdentifier:cbUUID];
        [self log:[NSString stringWithFormat:@"deviceFromIdentifier(%@) → %@",
                   cbUUID,
                   viaIdent ? NSStringFromClass([viaIdent class]) : @"nil"]];
        if (viaIdent) {
            NSString *name = @"?", *addr = @"?";
            @try { name = IRMStringValue([viaIdent name]); } @catch (__unused id e) {}
            @try { addr = IRMStringValue([viaIdent address]); } @catch (__unused id e) {}
            [self log:[NSString stringWithFormat:@"    name=%@  addr=%@", name, addr]];
        }
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"deviceFromIdentifier threw: %@", e.reason]];
    }

    // Old code path (kept for compatibility) — early-return so we don't double-print
    return;

    NSArray *devs = nil;
    @try {
        devs = [_bm pairedDevices];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"pairedDevices threw: %@", e.reason]];
        return;
    }
    [self log:[NSString stringWithFormat:@"pairedDevices.count = %lu", (unsigned long)devs.count]];
    for (id dev in devs) {
        NSString *name = @"?", *addr = @"?", *prod = @"?";
        BOOL conn = NO, paired = NO, audio = NO;
        NSInteger vid = 0, pid = 0, mic = -1, major = 0, minor = 0;
        @try { name   = IRMStringValue([dev name]); } @catch (__unused id e) {}
        @try { addr   = IRMStringValue([dev address]); } @catch (__unused id e) {}
        @try { prod   = IRMStringValue([dev productName]); } @catch (__unused id e) {}
        @try { conn   = [dev connected]; } @catch (__unused id e) {}
        @try { paired = [dev paired];    } @catch (__unused id e) {}
        @try { audio  = [dev isAppleAudioDevice]; } @catch (__unused id e) {}
        @try { vid    = [dev vendorId];  } @catch (__unused id e) {}
        @try { pid    = [dev productId]; } @catch (__unused id e) {}
        @try { mic    = [dev micMode];   } @catch (__unused id e) {}
        @try { major  = [dev majorClass]; } @catch (__unused id e) {}
        @try { minor  = [dev minorClass]; } @catch (__unused id e) {}
        [self log:[NSString stringWithFormat:
            @"  · name='%@' addr=%@ prod='%@' connected=%d paired=%d appleAudio=%d vid=0x%lX pid=0x%lX maj=%ld min=%ld micMode=%ld",
            name, addr, prod, conn, paired, audio, (long)vid, (long)pid, (long)major, (long)minor, (long)mic]];
    }
}

- (id)deviceForAddress:(NSString *)addr {
    if (!_bm || !addr) return nil;
    id dev = nil;
    @try {
        dev = [_bm deviceFromAddressString:addr];
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"deviceFromAddressString threw: %@", e.reason]];
        return nil;
    }
    if (!dev) {
        [self log:[NSString stringWithFormat:@"deviceFromAddressString(%@) returned nil — searching pairedDevices…", addr]];
        @try {
            for (id d in [_bm pairedDevices]) {
                NSString *a = IRMStringValue([d address]);
                if ([a caseInsensitiveCompare:addr] == NSOrderedSame) {
                    dev = d; break;
                }
            }
        } @catch (NSException *e) {
            [self log:[NSString stringWithFormat:@"fallback search threw: %@", e.reason]];
        }
    }
    return dev;
}

- (BOOL)triggerVoiceCommandForAddress:(NSString *)address {
    id dev = [self deviceForAddress:address];
    if (!dev) {
        [self log:[NSString stringWithFormat:@"no BluetoothDevice for %@", address]];
        return NO;
    }
    [self log:[NSString stringWithFormat:@"audio devices BEFORE: %@", [IRMAudioDevices summarizeInputs]]];
    @try {
        [dev startVoiceCommand];
        [self log:[NSString stringWithFormat:@"✓ -[%@ startVoiceCommand] returned (no exception)", NSStringFromClass([dev class])]];
        // Snapshot 0.5s later — give CoreAudio time to react if it's going to.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self log:[NSString stringWithFormat:@"audio devices +500ms: %@", [IRMAudioDevices summarizeInputs]]];
        });
        return YES;
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"✗ startVoiceCommand threw %@: %@", e.name, e.reason]];
        return NO;
    }
}

- (BOOL)endVoiceCommandForAddress:(NSString *)address {
    id dev = [self deviceForAddress:address];
    if (!dev) return NO;
    @try {
        [dev endVoiceCommand];
        [self log:@"✓ endVoiceCommand returned"];
        return YES;
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"✗ endVoiceCommand threw: %@", e.reason]];
        return NO;
    }
}

- (BOOL)sendSetupCommand:(uint8_t)byte forAddress:(NSString *)address {
    id dev = [self deviceForAddress:address];
    if (!dev) return NO;
    SEL sel = sel_registerName("SendSetupCommand:");
    if (![dev respondsToSelector:sel]) {
        [self log:@"device does not respond to SendSetupCommand:"];
        return NO;
    }
    @try {
        // Returns uint32_t; selector encoding is "I20@0:8C16"
        uint32_t (*fn)(id, SEL, uint8_t) = (uint32_t (*)(id, SEL, uint8_t))objc_msgSend;
        uint32_t result = fn(dev, sel, byte);
        [self log:[NSString stringWithFormat:@"SendSetupCommand(0x%02X) → 0x%08X", byte, result]];
        return YES;
    } @catch (NSException *e) {
        [self log:[NSString stringWithFormat:@"SendSetupCommand threw: %@", e.reason]];
        return NO;
    }
}

@end


// =====================================================================
// IRMAudioDevices — enumerate Core Audio input devices, used to detect
// the side effect (if any) of -[BluetoothDevice startVoiceCommand].
// =====================================================================

@implementation IRMAudioDevices

+ (NSArray<NSString *> *)inputDeviceNames {
    NSMutableArray *out = [NSMutableArray array];

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return out;
    UInt32 count = size / sizeof(AudioDeviceID);
    AudioDeviceID *ids = malloc(size);
    if (!ids) return out;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids) != noErr) {
        free(ids);
        return out;
    }

    for (UInt32 i = 0; i < count; i++) {
        // Skip non-input devices: query input-stream count
        AudioObjectPropertyAddress streamAddr = {
            kAudioDevicePropertyStreams,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        UInt32 streamSize = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &streamAddr, 0, NULL, &streamSize) != noErr) continue;
        if (streamSize == 0) continue;

        // Get the device name
        CFStringRef name = NULL;
        UInt32 nameSize = sizeof(name);
        AudioObjectPropertyAddress nameAddr = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(ids[i], &nameAddr, 0, NULL, &nameSize, &name) == noErr && name) {
            [out addObject:(__bridge_transfer NSString *)name];
        }
    }
    free(ids);
    return out;
}

+ (NSString *)summarizeInputs {
    NSArray *names = [self inputDeviceNames];
    if (names.count == 0) return @"(none)";
    return [names componentsJoinedByString:@" | "];
}

@end
