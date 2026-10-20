import FlutterMacOS
import IOKit

/// The KeyGrant plugin's macOS side (the SDK contract, section 4), over the channel
/// `dev.keygrant/keygrant`:
///
/// - `machineId`: the platform expert device's `IOPlatformUUID`, read in-process through IOKit
///   (`IOServiceGetMatchingService`, `IORegistryEntryCreateCFProperty`), the value
///   `/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice` prints, which a sandboxed Mac App Store build
///   could not launch. Nil when there is no platform expert or it has none (no id to read).
public class KeygrantPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dev.keygrant/keygrant", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(KeygrantPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "machineId":
            result(PlatformExpert.uuid())
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// The Mac's own id through IOKit.
enum PlatformExpert {
    /// The `IOPlatformUUID`, or nil. `MACH_PORT_NULL` is the default main port (what macOS 12
    /// named `kIOMainPortDefault`), so this builds for the older systems Flutter supports too.
    static func uuid() -> String? {
        let service = IOServiceGetMatchingService(mach_port_t(MACH_PORT_NULL), IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { _ = IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return property.takeRetainedValue() as? String
    }
}
