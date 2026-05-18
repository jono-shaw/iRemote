// Wrapper around Apple's private BluetoothManager.framework. Loaded at
// runtime via dlopen so the project still builds without private headers.
//
// Discovered API surface (Obj-C runtime introspection on macOS 26):
//   +[BluetoothManager sharedInstance]
//   -[BluetoothManager pairedDevices]               → NSArray<BluetoothDevice*>
//   -[BluetoothManager connectedDevices]            → NSArray<BluetoothDevice*>
//   -[BluetoothManager deviceFromAddressString:]    → BluetoothDevice*
//   -[BluetoothManager startVoiceCommand:]          (BluetoothDevice arg)
//   -[BluetoothManager endVoiceCommand:]
//   -[BluetoothDevice startVoiceCommand]            (no args)
//   -[BluetoothDevice endVoiceCommand]              (no args)
//   -[BluetoothDevice address] / name / productName / paired / connected
//   -[BluetoothDevice isAppleAudioDevice]
//   -[BluetoothDevice productId] / vendorId / majorClass / minorClass
//   -[BluetoothDevice micMode] / setMicMode:
//   -[BluetoothDevice SendSetupCommand:]            (uint8 arg, returns uint32)
//
// Anything called on the private API is wrapped in @try/@catch so a
// signature change in a future macOS doesn't crash the app.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IRMLogBlock)(NSString *line);

@interface IRMVoiceCommander : NSObject

- (instancetype)initWithLogger:(IRMLogBlock)logger;

/// dlopen the private framework and resolve the manager singleton.
/// Returns NO on failure (logs reason via the logger block).
- (BOOL)loadAndAttach;

/// Print every paired device's address/name/connected/audio properties.
- (void)dumpPairedDevices;

/// Try `[BluetoothDevice startVoiceCommand]` on the device matching the
/// given address (e.g. "28:EC:95:21:38:DC"). Logs the outcome.
- (BOOL)triggerVoiceCommandForAddress:(NSString *)address;

/// Try `[BluetoothDevice endVoiceCommand]`.
- (BOOL)endVoiceCommandForAddress:(NSString *)address;

/// Try `-[BluetoothDevice SendSetupCommand:]` with a single byte. Diagnostic.
- (BOOL)sendSetupCommand:(uint8_t)byte forAddress:(NSString *)address;

@end


/// Snapshot of system audio input devices, useful for observing what
/// changes (if anything) when startVoiceCommand fires.
@interface IRMAudioDevices : NSObject
+ (NSString *)summarizeInputs;
@end

NS_ASSUME_NONNULL_END
