import CoreBluetooth
import Foundation
import UIKit
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

/// The `associate`, `associations` and `disassociate` routes on iOS: AccessorySetupKit, the system
/// accessory picker (Apple, AccessorySetupKit, iOS 18.0+, read 2026-11-26). Android answers the same
/// routes with CompanionDeviceManager; the core is shared and asks this type through `BlePort`.
///
/// Nothing here shows or starts anything without the page's call:
/// - `associate` shows the system picker, once per call (`showPicker`), filtered by the one service UUID
///   (and name) the call gives;
/// - the `ASAccessorySession` is activated at launch only when the app declared AccessorySetupKit in its
///   Info.plist (activation shows nothing and is what makes `session.accessories` available when the
///   page first asks); an app that did not declare it never creates a session.
///
/// Apple (Discovering and configuring accessories): "If your app tries to discover Bluetooth accessories
/// during setup without supplying these keys and values, or uses identifiers, names, or services that it
/// doesn't include in its information property list, the app crashes." So a route whose filter is not
/// declared is answered `unavailable` before the picker is built, never crashes.
///
/// Declaring `NSAccessorySetupKitSupports` with `Bluetooth` also changes CoreBluetooth for the whole app
/// (Apple, WWDC24 "Meet AccessorySetupKit": people are not asked for Bluetooth permission, and the
/// central's state is only poweredOn while the app has paired accessories), so the extension never
/// declares it on its own: the developer adds the keys to their app's Info.plist when they want the
/// picker. Below iOS 18 the routes answer `platform_limit`.
///
/// Association numbers. AccessorySetupKit names an accessory by its Bluetooth identifier; the routes use
/// small integers like Android's, kept in `ble/accessories.json`. The answer also carries `id`, the
/// identifier every other route takes as a device id (`connect` finds the accessory by it); `address`
/// is null (iOS gives apps no Bluetooth address).
@MainActor
final class BleAccessories {
    static let below18 = "AccessorySetupKit needs iOS 18; earlier iOS has no accessory picker for an app"
    static let notDeclared = "the app does not declare AccessorySetupKit: add Bluetooth to NSAccessorySetupKitSupports and the "
        + "accessory's service to NSAccessorySetupBluetoothServices (and its name to NSAccessorySetupBluetoothNames) in the app's "
        + "Info.plist; declaring it limits CoreBluetooth to the accessories the person set up"

    private let file: URL
    private let log: (String) -> Void
    /// The picker's end: request, the accessory as a record, or "code message". Set by `BleExtension`.
    var answer: ((Int, BleObj?, String?) -> Void)?
    private var numbers: [String: Int] = [:]
    private var nextNumber = 1
    /// The open picker's request, or 0.
    private var open = 0
    private var session: AnyObject?

    init(dataDirectory: URL, log: @escaping (String) -> Void) {
        file = dataDirectory.appendingPathComponent("ble", isDirectory: true).appendingPathComponent("accessories.json")
        self.log = log
        if let d = try? Data(contentsOf: file),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            nextNumber = o["next"] as? Int ?? 1
            numbers = (o["numbers"] as? [String: Int]) ?? [:]
        }
    }

    // MARK: Info.plist

    private static func plistList(_ key: String) -> [String] {
        Bundle.main.object(forInfoDictionaryKey: key) as? [String] ?? []
    }

    /// The app declared Bluetooth in NSAccessorySetupKitSupports.
    static var declared: Bool { plistList("NSAccessorySetupKitSupports").contains("Bluetooth") }

    /// CBUUID(string:) raises on a malformed string; only these forms reach it.
    private static func normalized(_ s: String) -> String? {
        let hex = "[0-9A-Fa-f]"
        let ok = s.range(of: "^(\(hex){4}|\(hex){8}|\(hex){8}-\(hex){4}-\(hex){4}-\(hex){4}-\(hex){12})$", options: .regularExpression) != nil
        return ok ? CBUUID(string: s).uuidString : nil
    }

    // MARK: session

    /// Launch: with AccessorySetupKit declared on iOS 18, activate the session so the accessories the app
    /// already holds are there when the page asks. It shows nothing.
    func launch() {
        guard #available(iOS 18.0, *), BleAccessories.declared else { return }
        activate()
    }

    // MARK: routes (BlePort)

    func associate(_ request: Int, _ params: BleObj) -> String? {
        guard #available(iOS 18.0, *) else { return "platform_limit \(BleAccessories.below18)" }
        guard BleAccessories.declared else { return "unavailable \(BleAccessories.notDeclared)" }
        return pick(request, params)
    }

    func associations() -> Any {
        guard #available(iOS 18.0, *) else { return "platform_limit \(BleAccessories.below18)" }
        guard BleAccessories.declared else { return "unavailable \(BleAccessories.notDeclared)" }
        return list()
    }

    func disassociate(_ association: Int) -> String? {
        guard #available(iOS 18.0, *) else { return "platform_limit \(BleAccessories.below18)" }
        guard BleAccessories.declared else { return "unavailable \(BleAccessories.notDeclared)" }
        return remove(association)
    }

    // MARK: numbers

    private func number(for id: String) -> Int {
        if let n = numbers[id] { return n }
        let n = nextNumber
        nextNumber += 1
        numbers[id] = n
        if let d = try? JSONSerialization.data(withJSONObject: ["next": nextNumber, "numbers": numbers]) {
            do {
                try d.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                log("accessories file: \(error.localizedDescription)")
            }
        }
        return n
    }

    // MARK: AccessorySetupKit (iOS 18)

    #if canImport(AccessorySetupKit)
    @available(iOS 18.0, *)
    private var asSession: ASAccessorySession? { session as? ASAccessorySession }

    @available(iOS 18.0, *)
    private func activate() {
        guard session == nil else { return }
        let s = ASAccessorySession()
        session = s
        s.activate(on: DispatchQueue.main) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    @available(iOS 18.0, *)
    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .accessoryAdded:
            if let a = event.accessory, let info = record(a) { finish(info, nil) }
        case .pickerDidDismiss:
            closed()
        default:
            break
        }
    }

    @available(iOS 18.0, *)
    private func record(_ a: ASAccessory) -> BleObj? {
        guard let id = a.bluetoothIdentifier?.uuidString else { return nil }
        return BleCore.obj(("association", number(for: id)), ("address", NSNull()), ("name", a.displayName), ("id", id))
    }

    @available(iOS 18.0, *)
    private func list() -> Any {
        activate()
        return (asSession?.accessories ?? []).compactMap { record($0) as Any? }
    }

    @available(iOS 18.0, *)
    private func pick(_ request: Int, _ p: BleObj) -> String? {
        guard let service = (p["services"] as? [Any])?.first as? String, let uuid = BleAccessories.normalized(service) else {
            return "bad_value services is one service UUID"
        }
        guard BleAccessories.plistList("NSAccessorySetupBluetoothServices").compactMap(BleAccessories.normalized).contains(uuid) else {
            return "unavailable \(service) is not in NSAccessorySetupBluetoothServices; \(BleAccessories.notDeclared)"
        }
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(string: uuid)
        var title = "Bluetooth accessory"
        if let n = p["name"] as? String, !n.isEmpty {
            guard BleAccessories.plistList("NSAccessorySetupBluetoothNames").contains(n) else {
                return "unavailable \(n) is not in NSAccessorySetupBluetoothNames; \(BleAccessories.notDeclared)"
            }
            descriptor.bluetoothNameSubstring = n
            title = n
        }
        guard open == 0 else { return "busy the accessory picker is already open" }
        activate()
        let image = UIImage(systemName: "dot.radiowaves.left.and.right")?
            .withTintColor(.label, renderingMode: .alwaysOriginal) ?? UIImage()
        let item = ASPickerDisplayItem(name: title, productImage: image, descriptor: descriptor)
        open = request
        asSession?.showPicker(for: [item]) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let error = error else { self?.closed(); return }
                    self?.failed(request, error)
                }
            }
        }
        return nil
    }

    @available(iOS 18.0, *)
    private func remove(_ association: Int) -> String? {
        guard let id = numbers.first(where: { $0.value == association })?.key,
              let a = asSession?.accessories.first(where: { $0.bluetoothIdentifier?.uuidString == id }) else {
            return "not_associated the association is not this app's"
        }
        asSession?.removeAccessory(a) { [weak self] error in
            if let error = error { self?.log("removeAccessory: \(error.localizedDescription)") }
        }
        return nil
    }

    @available(iOS 18.0, *)
    private func failed(_ request: Int, _ error: Error) {
        guard open == request else { return }
        open = 0
        if let e = error as? ASError, e.code == .userCancelled {
            answer?(request, nil, "cancelled the accessory picker was closed")
        } else {
            answer?(request, nil, "associate_failed \(error.localizedDescription)")
        }
    }
    #else
    private func activate() {}
    private func pick(_ request: Int, _ p: BleObj) -> String? { "platform_limit \(BleAccessories.below18)" }
    private func list() -> Any { "platform_limit \(BleAccessories.below18)" }
    private func remove(_ association: Int) -> String? { "platform_limit \(BleAccessories.below18)" }
    #endif

    /// The accessory the person set up: answers the open picker.
    private func finish(_ info: BleObj, _ err: String?) {
        guard open > 0 else { return }
        let r = open
        open = 0
        answer?(r, info, err)
    }

    /// The picker went away. The accessory event comes first when the person picked one; with the picker
    /// still open a moment later, the person closed it.
    private func closed() {
        let r = open
        guard r > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.open == r else { return }
                self.open = 0
                self.answer?(r, nil, "cancelled the accessory picker was closed")
            }
        }
    }
}
