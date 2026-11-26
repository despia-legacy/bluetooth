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
///   and/or company identifier (`manufacturer_id`, with `manufacturer_hex` as the manufacturer data blob) and
///   the name the call gives; with `migrate` it carries an `ASMigrationDisplayItem` for a device the app
///   already uses through CoreBluetooth;
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
        + "accessory's service to NSAccessorySetupBluetoothServices (or its company identifier to "
        + "NSAccessorySetupBluetoothCompanyIdentifiers, four hex digits like 004C), and its name to NSAccessorySetupBluetoothNames, in the app's "
        + "Info.plist; declaring it limits CoreBluetooth to the accessories the person set up"
    static let migrationAfterCentral = "migrate needs a run in which no CBCentralManager exists yet: Apple fails the picker when one "
        + "was created before the migration is complete. Call associate with migrate before any other ble route in that run"

    private let file: URL
    /// Written once an accessory was set up through AccessorySetupKit (a migration completed, or a picked
    /// accessory was added): from then on a launch may recreate the central manager (BleCore.launchCreatesCentral).
    private let migratedFile: URL
    private let log: (String) -> Void
    /// The picker's end: request, the accessory as a record, or "code message". Set by `BleExtension`.
    var answer: ((Int, BleObj?, String?) -> Void)?
    private var numbers: [String: Int] = [:]
    private var nextNumber = 1
    /// The open picker's request, or 0.
    private var open = 0
    private var session: AnyObject?
    /// The open picker's migration: the device id (upper-case UUID) and the display name it carries.
    private var migrating: (id: String, name: String)?

    init(dataDirectory: URL, log: @escaping (String) -> Void) {
        file = dataDirectory.appendingPathComponent("ble", isDirectory: true).appendingPathComponent("accessories.json")
        migratedFile = dataDirectory.appendingPathComponent("ble", isDirectory: true).appendingPathComponent("migrated")
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

    /// NSAccessorySetupBluetoothCompanyIdentifiers: an array of strings, each "a two-byte UUID" (Apple, read
    /// 2026-11-26): four hex digits like `004C`. Any other spelling (`0x004C` included) is not declared, so a call that
    /// names such an id answers `unavailable` instead of crashing the picker (BleCore.companyIdentifier).
    static var companyIdentifiers: Set<Int> {
        Set(plistList("NSAccessorySetupBluetoothCompanyIdentifiers").compactMap(BleCore.companyIdentifier))
    }

    /// CBUUID(string:) raises on a malformed string; only these forms reach it.
    private static func normalized(_ s: String) -> String? {
        let hex = "[0-9A-Fa-f]"
        let ok = s.range(of: "^(\(hex){4}|\(hex){8}|\(hex){8}-\(hex){4}-\(hex){4}-\(hex){4}-\(hex){12})$", options: .regularExpression) != nil
        return ok ? CBUUID(string: s).uuidString : nil
    }

    /// An accessory has been set up through AccessorySetupKit in this install (see `migratedFile`).
    var migrationDone: Bool { FileManager.default.fileExists(atPath: migratedFile.path) }

    private func markMigrationDone() {
        guard !migrationDone else { return }
        FileManager.default.createFile(atPath: migratedFile.path, contents: Data(),
                                       attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
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
            markMigrationDone()
            if let a = event.accessory, let info = record(a) { finish(info, nil) }
        case .migrationComplete:
            // Apple lists this apart from accessoryAdded: "The migration of an accessory completed". It answers the
            // request that carried the migration item, with the accessory when the event has one, else the device
            // the call named. Never `cancelled`: pickerDidDismiss follows it, and `closed()` finds no open request.
            markMigrationDone()
            if let a = event.accessory, let info = record(a) {
                finish(info, nil)
            } else if let m = migrating, open > 0 {
                finish(BleCore.obj(("association", number(for: m.id)), ("address", NSNull()), ("name", m.name), ("id", m.id)), nil)
            }
        case .pickerDidDismiss:
            closed()
        case .pickerSetupFailed:
            // The setup of the picked accessory failed: the page gets associate_failed now, not the route timeout.
            if open > 0 { failed(open, event.error ?? BleAccessories.SetupFailed()) }
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
        let descriptor = ASDiscoveryDescriptor()
        if let service = (p["services"] as? [Any])?.first as? String {
            guard let uuid = BleAccessories.normalized(service) else { return "bad_value services is one service UUID" }
            guard BleAccessories.plistList("NSAccessorySetupBluetoothServices").compactMap(BleAccessories.normalized).contains(uuid) else {
                return "unavailable \(service) is not in NSAccessorySetupBluetoothServices; \(BleAccessories.notDeclared)"
            }
            descriptor.bluetoothServiceUUID = CBUUID(string: uuid)
        }
        if let id = p["manufacturerId"] as? Int {
            guard id >= 0, id <= 0xFFFF, BleAccessories.companyIdentifiers.contains(id) else {
                return "unavailable company identifier \(String(format: "%04X", id)) is not in NSAccessorySetupBluetoothCompanyIdentifiers; \(BleAccessories.notDeclared)"
            }
            descriptor.bluetoothCompanyIdentifier = ASBluetoothCompanyIdentifier(rawValue: UInt16(id))
            if let hex = p["manufacturerHex"] as? String, let bytes = BleCore.fromHex(hex), !bytes.isEmpty {
                descriptor.bluetoothManufacturerDataBlob = Data(bytes)
                descriptor.bluetoothManufacturerDataMask = Data(repeating: 0xFF, count: bytes.count)
            }
        }
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
        let item: ASPickerDisplayItem
        if let id = p["migrate"] as? String, let device = UUID(uuidString: id) {
            // One-time migration of a device the app already set up through CoreBluetooth (Apple, "Use the picker
            // when migrating to AccessorySetupKit").
            let m = ASMigrationDisplayItem(name: title, productImage: image, descriptor: descriptor)
            m.peripheralIdentifier = device
            item = m
            migrating = (device.uuidString, title)
        } else {
            item = ASPickerDisplayItem(name: title, productImage: image, descriptor: descriptor)
            migrating = nil
        }
        open = request
        asSession?.showPicker(for: [item]) { [weak self] error in
            // The completion is not the picker's end (Apple: it runs "when it completes the operation", and the
            // session reports pickerDidPresent and pickerDidDismiss itself): only its error ends the request.
            guard let error = error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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
            guard let error = error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.log("removeAccessory: \(error.localizedDescription)") }
            }
        }
        return nil
    }

    @available(iOS 18.0, *)
    private func failed(_ request: Int, _ error: Error) {
        guard open == request else { return }
        open = 0
        // Not `error as? ASError`: bridging ASError names the C global ASErrorDomain, which carries no availability, so
        // the app would link AccessorySetupKit strongly and dyld would refuse to start it on iOS 16 and 17 (the deployment
        // target is 16.6). The domain and ASErrorCodeUserCancelled (700, ASErrors.h) are compared by value instead.
        let e = error as NSError
        if e.domain == "ASErrorDomain" && e.code == 700 {
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

    /// The error of a pickerSetupFailed event that carries none.
    struct SetupFailed: LocalizedError {
        var errorDescription: String? { "the accessory could not be set up" }
    }

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
