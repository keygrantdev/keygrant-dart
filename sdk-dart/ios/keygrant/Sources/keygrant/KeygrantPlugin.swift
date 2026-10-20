import Flutter
import Security
import UIKit

/// The KeyGrant plugin's iOS side (the SDK contract, section 4.1), over the channel
/// `dev.keygrant/keygrant`:
///
/// - `machineId` (`product`): the install id kept in the Keychain (a generic password, service
///   `dev.keygrant.install`, account the product slug, accessible after first unlock, this device
///   only, never synced to iCloud nor restored onto another device). The first read that finds
///   none writes one, seeded from `UIDevice.identifierForVendor` (its UUID text, upper case), or a
///   random version 4 UUID when that is nil. A Keychain call that fails answers an error: no
///   fingerprint this time, read again next call, never `identifierForVendor` in its place.
/// - `readTrialStart` / `writeTrialStart` (`product`, `start`): the trial's start, the registry
///   stash, kept in the Keychain under service `dev.keygrant.trial`, which outlives the app.
public class KeygrantPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dev.keygrant/keygrant", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(KeygrantPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        let product = arguments["product"] as? String ?? ""
        do {
            switch call.method {
            case "machineId":
                result(try Keychain.installId(account: product))
            case "readTrialStart":
                let kept = try Keychain.read(service: Keychain.trialService, account: product)
                result(kept.flatMap { Int64($0) })
            case "writeTrialStart":
                guard let start = (arguments["start"] as? NSNumber)?.int64Value, start > 0 else {
                    result(FlutterError(code: "bad-arguments", message: "a trial start in ms", details: nil))
                    return
                }
                try Keychain.write(String(start), service: Keychain.trialService, account: product)
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch let error as KeychainError {
            result(FlutterError(code: "keychain", message: "the Keychain answered \(error.status)", details: Int(error.status)))
        } catch {
            result(FlutterError(code: "keychain", message: "\(error)", details: nil))
        }
    }
}

/// A Keychain call that did not succeed.
struct KeychainError: Error {
    let status: OSStatus
}

/// The plugin's generic-password items.
enum Keychain {
    static let installService = "dev.keygrant.install"
    static let trialService = "dev.keygrant.trial"

    /// The install id for `account`, written once (seeded from `identifierForVendor`) when none is kept.
    static func installId(account: String) throws -> String {
        if let kept = try read(service: installService, account: account), !kept.isEmpty { return kept }
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        do {
            try add(seed.uppercased(), service: installService, account: account)
        } catch let error as KeychainError where error.status == errSecDuplicateItem {
            // Another call wrote one in between: that one is the install's.
        }
        guard let id = try read(service: installService, account: account), !id.isEmpty else {
            throw KeychainError(status: errSecItemNotFound)
        }
        return id
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// The item's text, or nil when there is none.
    static func read(service: String, account: String) throws -> String? {
        var search = query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func add(_ text: String, service: String, account: String) throws {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = Data(text.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// The item set to `text`, made when there is none.
    static func write(_ text: String, service: String, account: String) throws {
        let change = [kSecValueData as String: Data(text.utf8)]
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary, change as CFDictionary)
        if status == errSecItemNotFound {
            try add(text, service: service, account: account)
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
