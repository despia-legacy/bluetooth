import CoreBluetooth
import Foundation

/// The CoreBluetooth central behind `BleCore`: one CBCentralManager with state restoration, the
/// scanner and the GATT client. It makes no decision of its own; it translates CoreBluetooth
/// callbacks into core inputs and does what the core asks through `BleExtension`'s port.
///
/// The manager is created only when a route needs Bluetooth (which can show the permission prompt)
/// or when iOS relaunched the app to restore it (`restoreBluetoothCentrals`, before launch returns,
/// as CoreBluetooth requires). Its restore identifier is the one the build declared
/// (`claims.bluetooth_centrals: ["main"]`, full form `nativeext.ble.main`).
///
/// Tokens. CoreBluetooth keeps one CBPeripheral per device, so a callback carries no attempt; the
/// radio holds one session per device id with the core's `gen` for the attempt, and every callback
/// reaches the core with that gen. The core allows one live attempt per device (it waits for the
/// confirmed close before the next connect), so a session is never shared by two attempts.
///
/// Executor: the manager is created with `queue: nil`, which CoreBluetooth documents as the main
/// queue for every central-role and peripheral event, so both delegate conformances are isolated to
/// the main actor (`@MainActor CBCentralManagerDelegate`, `@MainActor CBPeripheralDelegate`,
/// SE-0470) and each witness checks at run time that it was called on the main queue.
@MainActor
final class BleCentralRadio: NSObject, @MainActor CBCentralManagerDelegate, @MainActor CBPeripheralDelegate {
    static let cccd = CBUUID(string: "2902")

    /// One connection attempt of one device.
    final class Session {
        let gen: Int
        let peripheral: CBPeripheral
        var connected = false
        var pendingOp = 0
        var pendingKind: String?
        var pendingKey: String?
        var pendingDescriptor: CBDescriptor?
        var pendingMode: String?
        /// A write without response waiting for `peripheralIsReady`.
        var pendingWrite: (CBCharacteristic, Data)?
        /// Discovery steps still running (services, included services, characteristics, descriptors).
        var discovering = 0
        /// A restored peripheral that iOS did not keep connecting: connect it once the radio is on.
        var reconnectWhenOn = false

        init(_ gen: Int, _ peripheral: CBPeripheral) {
            self.gen = gen
            self.peripheral = peripheral
        }
    }

    private let core: BleCore
    private let restoreIdentifier: String
    private(set) var manager: CBCentralManager?
    private var sessions: [String: Session] = [:]
    /// Peripherals seen by a scan or restored, by id, so connect can find them.
    private var known: [String: CBPeripheral] = [:]
    private var scanning = 0
    /// A scan iOS restored, to be handed to the core once the radio is on.
    private var restoredScan: [String]?
    private var readyWaiters: [Waiter] = []

    final class Waiter {
        var continuation: CheckedContinuation<Void, Never>?

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    init(core: BleCore, restoreIdentifier: String) {
        self.core = core
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    var hasManager: Bool { manager != nil }

    /// on, off, unauthorized, unsupported, resetting or unknown; unknown before the manager exists.
    var stateName: String {
        guard let m = manager else {
            return CBManager.authorization == .denied || CBManager.authorization == .restricted ? "unauthorized" : "unknown"
        }
        return BleCentralRadio.name(m.state)
    }

    static func name(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    static func authorizationName(_ a: CBManagerAuthorization) -> String {
        switch a {
        case .allowedAlways: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "not_determined"
        }
    }

    @discardableResult
    func makeManager() -> CBCentralManager {
        if let m = manager { return m }
        let m = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier,
        ])
        manager = m
        return m
    }

    /// Creates the manager when needed and waits until its state is known (the first update can
    /// follow the permission prompt), or until `deadline`.
    func ready(until deadline: DispatchTime) async {
        let m = makeManager()
        if m.state != .unknown { return }
        let w = Waiter()
        readyWaiters.append(w)
        let ns = deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds
            ? deadline.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds : 0
        Task { @MainActor [weak w] in
            try? await Task.sleep(nanoseconds: ns)
            w?.resume()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if m.state != .unknown {
                c.resume()
            } else {
                w.continuation = c
            }
        }
        readyWaiters.removeAll { $0 === w }
    }

    // MARK: scan

    func scanStart(_ scan: Int, _ services: [String], _ duplicates: Bool, _ mode: String) -> String? {
        // `mode` is Android's ScanSettings scan mode; CoreBluetooth has no scan mode to set.
        guard let m = manager, m.state == .poweredOn else { return "unavailable Bluetooth is \(stateName)" }
        let ids = services.map { CBUUID(string: $0) }
        m.scanForPeripherals(withServices: ids.isEmpty ? nil : ids,
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: duplicates])
        scanning = scan
        return nil
    }

    func scanStop(_ scan: Int) {
        guard scanning == scan else { return }
        scanning = 0
        if let m = manager, m.state == .poweredOn { m.stopScan() }
    }

    static func uuid(_ u: CBUUID) -> String {
        BleCore.uuid(u.uuidString) ?? u.uuidString.lowercased()
    }

    /// Every advertisement field CoreBluetooth reports, in the core's record form.
    static func advertisement(_ p: CBPeripheral, _ data: [String: Any], _ rssi: NSNumber) -> BleObj {
        let adv = BleObj()
        if let name = (data[CBAdvertisementDataLocalNameKey] as? String) ?? p.name { adv["name"] = name }
        // 127 is CoreBluetooth's "RSSI not available".
        if rssi.intValue != 127 { adv["rssi"] = rssi.intValue }
        if let c = data[CBAdvertisementDataIsConnectable] as? NSNumber { adv["connectable"] = c.boolValue }
        if let tx = data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { adv["txPower"] = tx.intValue }
        var services: [Any] = []
        for key in [CBAdvertisementDataServiceUUIDsKey, CBAdvertisementDataOverflowServiceUUIDsKey] {
            for u in (data[key] as? [CBUUID]) ?? [] { services.append(uuid(u)) }
        }
        var manufacturer: [Any] = []
        if let d = data[CBAdvertisementDataManufacturerDataKey] as? Data, d.count >= 2 {
            let b = [UInt8](d)
            manufacturer.append(BleCore.obj(("id", Int(b[0]) | Int(b[1]) << 8), ("hex", BleCore.hex(Array(b[2...])))))
        }
        var serviceData: [Any] = []
        if let sd = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (u, d) in sd.sorted(by: { uuid($0.key) < uuid($1.key) }) {
                serviceData.append(BleCore.obj(("uuid", uuid(u)), ("hex", BleCore.hex([UInt8](d)))))
            }
        }
        adv["services"] = services
        adv["manufacturer"] = manufacturer
        adv["serviceData"] = serviceData
        return adv
    }

    // MARK: links

    func connect(_ id: String, _ gen: Int, _ auto: Bool, _ background: Bool) -> String? {
        guard let m = manager, m.state == .poweredOn else { return "unavailable Bluetooth is \(stateName)" }
        guard let u = UUID(uuidString: id) else { return "unknown_device \(id)" }
        guard let p = known[id] ?? m.retrievePeripherals(withIdentifiers: [u]).first else {
            return "unknown_device this device was not seen by a scan on this phone"
        }
        known[id] = p
        p.delegate = self
        sessions[id] = Session(gen, p)
        // iOS keeps a pending connection without a time limit; the core's connect timer bounds a
        // requested connect, and an automatic reconnect waits for the device.
        m.connect(p, options: nil)
        return nil
    }

    private func session(_ p: CBPeripheral) -> Session? {
        let s = sessions[p.identifier.uuidString]
        return s?.peripheral === p ? s : nil
    }

    func close(_ id: String, _ gen: Int) -> Bool {
        guard let s = sessions[id], s.gen == gen else { return true }
        guard let m = manager, m.state == .poweredOn else {
            sessions[id] = nil
            return true
        }
        // Connected or pending, the close is confirmed by didDisconnectPeripheral; if none comes,
        // the core's close timer releases the session.
        m.cancelPeripheralConnection(s.peripheral)
        return false
    }

    func release(_ id: String, _ gen: Int) {
        guard let s = sessions[id], s.gen == gen else { return }
        sessions[id] = nil
        if let m = manager, m.state == .poweredOn, s.peripheral.state != .disconnected {
            m.cancelPeripheralConnection(s.peripheral)
        }
    }

    // MARK: GATT client

    static func properties(_ p: CBCharacteristicProperties) -> [Any] {
        var out: [Any] = []
        if p.contains(.broadcast) { out.append("broadcast") }
        if p.contains(.read) { out.append("read") }
        if p.contains(.writeWithoutResponse) { out.append("writeWithoutResponse") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.notify) || p.contains(.notifyEncryptionRequired) { out.append("notify") }
        if p.contains(.indicate) || p.contains(.indicateEncryptionRequired) { out.append("indicate") }
        if p.contains(.authenticatedSignedWrites) { out.append("authenticatedSignedWrites") }
        if p.contains(.extendedProperties) { out.append("extendedProperties") }
        return out
    }

    /// The key of a characteristic: service and characteristic UUIDs with their instance numbers.
    static func key(_ p: CBPeripheral, _ c: CBCharacteristic) -> String? {
        guard let svc = c.service else { return nil }
        var sn = 0
        for x in p.services ?? [] {
            if x === svc { break }
            if x.uuid == svc.uuid { sn += 1 }
        }
        var cn = 0
        for x in svc.characteristics ?? [] {
            if x === c { break }
            if x.uuid == c.uuid { cn += 1 }
        }
        return BleCore.key(uuid(svc.uuid), sn, uuid(c.uuid), cn)
    }

    static func resolve(_ p: CBPeripheral, _ key: String) -> CBCharacteristic? {
        let parts = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
        guard parts.count == 4, var sn = Int(parts[1]), var cn = Int(parts[3]) else { return nil }
        let su = CBUUID(string: parts[0]), cu = CBUUID(string: parts[2])
        for svc in p.services ?? [] where svc.uuid == su {
            if sn > 0 {
                sn -= 1
                continue
            }
            for c in svc.characteristics ?? [] where c.uuid == cu {
                if cn == 0 { return c }
                cn -= 1
            }
            return nil
        }
        return nil
    }

    func op(_ id: String, _ gen: Int, _ op: Int, _ kind: String, _ key: String?, _ descriptor: String?,
            _ data: [UInt8]?, _ arg: Int) -> String? {
        guard let s = sessions[id], s.gen == gen, s.connected else { return "not_connected the link is not connected" }
        let p = s.peripheral
        switch kind {
        case "discover":
            begin(s, op, kind)
            p.discoverServices(nil)
            return nil
        case "rssi":
            begin(s, op, kind)
            p.readRSSI()
            return nil
        default:
            break
        }
        guard let key = key, let c = BleCentralRadio.resolve(p, key) else {
            return "not_found no such characteristic (run discover first)"
        }
        var d: CBDescriptor?
        if let du = descriptor {
            d = (c.descriptors ?? []).first { $0.uuid == CBUUID(string: du) }
            if d == nil { return "not_found no such descriptor" }
        }
        switch kind {
        case "read":
            if let d = d {
                begin(s, op, kind, key: key, descriptor: d)
                p.readValue(for: d)
                return nil
            }
            guard c.properties.contains(.read) else { return "not_permitted the characteristic is not readable" }
            begin(s, op, kind, key: key)
            p.readValue(for: c)
            return nil
        case "write":
            let value = Data(data ?? [])
            if let d = d {
                // CoreBluetooth refuses writes to the CCCD through writeValue(_:for:) (subscribe sets it).
                if d.uuid == BleCentralRadio.cccd { return "not_permitted the CCCD is written by subscribe" }
                begin(s, op, kind, key: key, descriptor: d)
                p.writeValue(value, for: d)
                return nil
            }
            guard c.properties.contains(.write) else {
                return "not_permitted the characteristic does not accept a write with response"
            }
            begin(s, op, kind, key: key)
            p.writeValue(value, for: c, type: .withResponse)
            return nil
        case "wnr":
            guard c.properties.contains(.writeWithoutResponse) else {
                return "not_permitted the characteristic does not accept a write without response"
            }
            begin(s, op, kind, key: key)
            s.pendingWrite = (c, Data(data ?? []))
            sendPendingWrite(s)
            return nil
        case "sub", "unsub":
            let on = kind == "sub"
            let props = c.properties
            let notify = props.contains(.notify) || props.contains(.notifyEncryptionRequired)
            let indicate = props.contains(.indicate) || props.contains(.indicateEncryptionRequired)
            guard notify || indicate else { return "not_permitted the characteristic neither notifies nor indicates" }
            begin(s, op, kind, key: key, mode: on ? (notify ? "notify" : "indicate") : nil)
            p.setNotifyValue(on, for: c)
            return nil
        default:
            return "bad_value unknown operation \(kind)"
        }
    }

    private func begin(_ s: Session, _ op: Int, _ kind: String, key: String? = nil, descriptor: CBDescriptor? = nil,
                       mode: String? = nil) {
        s.pendingOp = op
        s.pendingKind = kind
        s.pendingKey = key
        s.pendingDescriptor = descriptor
        s.pendingMode = mode
        s.discovering = 0
    }

    /// A write without response goes out when the peripheral can take it; it is settled after the
    /// handoff, on a later main-queue turn (a port call never calls back into the core).
    private func sendPendingWrite(_ s: Session) {
        guard let w = s.pendingWrite, s.peripheral.canSendWriteWithoutResponse else { return }
        s.pendingWrite = nil
        s.peripheral.writeValue(w.1, for: w.0, type: .withoutResponse)
        let op = s.pendingOp, gen = s.gen
        Task { @MainActor [weak self, weak s] in
            guard let self = self, let s = s, s.pendingOp == op, s.pendingKind == "wnr" else { return }
            self.complete(s, gen, nil, nil, nil)
        }
    }

    private func complete(_ s: Session, _ gen: Int, _ code: String?, _ message: String?, _ data: BleObj?) {
        let op = s.pendingOp
        s.pendingKind = nil
        s.pendingKey = nil
        s.pendingDescriptor = nil
        s.pendingMode = nil
        s.pendingWrite = nil
        core.opDone(s.peripheral.identifier.uuidString, gen, op, code, message, data)
    }

    private func done(_ s: Session, _ error: Error?, _ data: BleObj?) {
        if let e = error {
            let att = (e as? CBATTError)?.code
            let code = att == .readNotPermitted || att == .writeNotPermitted ? "not_permitted" : "gatt_error"
            complete(s, s.gen, code, e.localizedDescription, nil)
            return
        }
        complete(s, s.gen, nil, nil, data)
    }

    private func discovered(_ s: Session) {
        var out: [Any] = []
        var sn: [String: Int] = [:]
        for svc in s.peripheral.services ?? [] {
            let su = BleCentralRadio.uuid(svc.uuid)
            let n = sn[su, default: 0]
            sn[su] = n + 1
            var chars: [Any] = []
            var cn: [String: Int] = [:]
            for c in svc.characteristics ?? [] {
                let cu = BleCentralRadio.uuid(c.uuid)
                let m = cn[cu, default: 0]
                cn[cu] = m + 1
                let descs: [Any] = (c.descriptors ?? []).map { BleCentralRadio.uuid($0.uuid) }
                chars.append(BleCore.obj(("uuid", cu), ("n", m), ("properties", BleCentralRadio.properties(c.properties)),
                                         ("descriptors", descs)))
            }
            let included: [Any] = (svc.includedServices ?? []).map { BleCentralRadio.uuid($0.uuid) }
            out.append(BleCore.obj(("uuid", su), ("n", n), ("primary", svc.isPrimary), ("included", included),
                                   ("characteristics", chars)))
        }
        complete(s, s.gen, nil, nil, BleCore.obj(("services", out)))
    }

    private func discoveryStep(_ s: Session, _ error: Error?) {
        guard s.pendingKind == "discover" else { return }
        if let e = error {
            complete(s, s.gen, "gatt_error", "service discovery failed: \(e.localizedDescription)", nil)
            return
        }
        s.discovering -= 1
        if s.discovering <= 0 { discovered(s) }
    }

    /// A descriptor value in bytes: CoreBluetooth gives Data, NSNumber (CCCD and the extended
    /// properties, 16-bit) or String (user description).
    static func descriptorBytes(_ v: Any?) -> [UInt8] {
        if let d = v as? Data { return [UInt8](d) }
        if let n = v as? NSNumber {
            let u = n.uint16Value
            return [UInt8(u & 0xff), UInt8(u >> 8)]
        }
        if let s = v as? String { return Array(s.utf8) }
        return []
    }

    // MARK: CBCentralManagerDelegate (main queue)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(.main))
        if central.state != .unknown {
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume() }
        }
        if central.state != .poweredOn {
            scanning = 0
            // The radio is off: every link of the old epoch is gone (the core releases each one).
            for s in sessions.values { s.connected = false }
        }
        core.adapter(BleCentralRadio.name(central.state))
        guard central.state == .poweredOn else { return }
        if let services = restoredScan {
            restoredScan = nil
            // The scan iOS kept for this app, handed to the core with no route waiting (call -1).
            core.scanStart(-1, services.joined(separator: ","), 0, false, "balanced", true)
        }
        for s in sessions.values where s.reconnectWhenOn {
            s.reconnectWhenOn = false
            central.connect(s.peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let peripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        var ids: [Any] = []
        for p in peripherals {
            let id = p.identifier.uuidString
            p.delegate = self
            known[id] = p
            var subscribed: [String] = []
            for svc in p.services ?? [] {
                for c in svc.characteristics ?? [] where c.isNotifying {
                    if let k = BleCentralRadio.key(p, c) { subscribed.append(k) }
                }
            }
            let connected = p.state == .connected
            let gen = core.restored(id, connected: connected, subscribed: subscribed, pending: p.state == .connecting)
            let s = Session(gen, p)
            s.connected = connected
            s.reconnectWhenOn = p.state == .disconnected
            sessions[id] = s
            ids.append(id)
        }
        let scan = ((dict[CBCentralManagerRestoredStateScanServicesKey] as? [CBUUID]) ?? []).map { BleCentralRadio.uuid($0) }
        if !scan.isEmpty { restoredScan = scan }
        core.restoredEvent(BleCore.obj(("peripherals", ids), ("scanning", !scan.isEmpty)))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard scanning != 0 else { return }
        let id = peripheral.identifier.uuidString
        known[id] = peripheral
        core.device(scanning, id, BleCentralRadio.advertisement(peripheral, advertisementData, RSSI))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        s.connected = true
        core.connected(peripheral.identifier.uuidString, s.gen, peripheral.maximumWriteValueLength(for: .withoutResponse) + 3)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        sessions[peripheral.identifier.uuidString] = nil
        core.disconnected(peripheral.identifier.uuidString, s.gen, "failed", error: BleCentralRadio.platformError(error))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        sessions[peripheral.identifier.uuidString] = nil
        core.disconnected(peripheral.identifier.uuidString, s.gen, "remote", error: BleCentralRadio.platformError(error))
    }

    /// CoreBluetooth's error as the page sees it: its domain, code and description, never dropped.
    static func platformError(_ error: Error?) -> BleObj? {
        guard let e = error as NSError? else { return nil }
        return BleCore.platformError(e.domain, e.code, e.localizedDescription)
    }

    // MARK: CBPeripheralDelegate (main queue)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "discover" else { return }
        if let e = error {
            complete(s, s.gen, "gatt_error", "service discovery failed: \(e.localizedDescription)", nil)
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            discovered(s)
            return
        }
        s.discovering = services.count * 2
        for svc in services {
            peripheral.discoverIncludedServices(nil, for: svc)
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        discoveryStep(s, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "discover" else { return }
        if error == nil {
            for c in service.characteristics ?? [] {
                s.discovering += 1
                peripheral.discoverDescriptors(for: c)
            }
        }
        discoveryStep(s, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        discoveryStep(s, error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), let k = BleCentralRadio.key(peripheral, characteristic) else { return }
        if let e = error {
            if s.pendingKind == "read", s.pendingDescriptor == nil, s.pendingKey == k { done(s, e, nil) }
            return
        }
        // iOS does not say whether this answers a read or is a notification; the core decides.
        let hex = BleCore.hex([UInt8](characteristic.value ?? Data()))
        if s.pendingKind == "read", s.pendingDescriptor == nil, s.pendingKey == k {
            s.pendingKind = nil
            s.pendingKey = nil
        }
        core.value(peripheral.identifier.uuidString, s.gen, k, hex, true)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "read", s.pendingDescriptor === descriptor else { return }
        done(s, error, error == nil ? BleCore.obj(("hex", BleCore.hex(BleCentralRadio.descriptorBytes(descriptor.value)))) : nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "write", s.pendingDescriptor == nil,
              s.pendingKey == BleCentralRadio.key(peripheral, characteristic) else { return }
        done(s, error, nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "write", s.pendingDescriptor === descriptor else { return }
        done(s, error, nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "sub" || s.pendingKind == "unsub",
              s.pendingKey == BleCentralRadio.key(peripheral, characteristic) else { return }
        done(s, error, s.pendingMode.map { BleCore.obj(("mode", $0)) })
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral), s.pendingKind == "rssi" else { return }
        done(s, error, BleCore.obj(("rssi", RSSI.intValue)))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        sendPendingWrite(s)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let s = session(peripheral) else { return }
        core.gattChanged(peripheral.identifier.uuidString, s.gen)
    }
}
