import CoreBluetooth
import Foundation

/// The CoreBluetooth peripheral behind `BleCore`: one CBPeripheralManager with state restoration,
/// the GATT server and the advertiser. It makes no decision of its own; it translates CoreBluetooth
/// callbacks into core inputs and does what the core asks through `BleExtension`'s port.
///
/// The manager is created only when a server route needs Bluetooth, or at launch when
/// `ble-server.json` exists in the extension's data directory: iOS restores a peripheral manager
/// only when the app creates it again with the same identifier during launch, and the NX runtime
/// does not route `.bluetoothPeripherals` (a recorded runtime gap), so the file is the launch signal.
/// Once the manager's first state settled: iOS called `willRestoreState`, so the core adopts the
/// restored services with the file's values (`BleCore.serverRestored`); or it did not, an ordinary
/// launch, and the file is deleted (`BleCore.serverFileAction`). An unreadable file is moved aside,
/// never overwritten, and reads of the restored services then answer `unlikely`.
///
/// Characteristics are created without a value, so every read reaches the core's value store;
/// writes are applied by the core all or none. Bluetooth going off removes the local database and
/// stops advertising (CoreBluetooth's own rule); the core re-adds under its next epoch.
///
/// Executor: the manager is created with `queue: nil`, the main queue, so the delegate conformance
/// is isolated to the main actor (`@MainActor CBPeripheralManagerDelegate`, SE-0470) and each witness
/// checks at run time that it was called on the main queue.
@MainActor
final class BlePeripheralRadio: NSObject, @MainActor CBPeripheralManagerDelegate, @MainActor StreamDelegate {
    private let core: BleCore
    private let restoreIdentifier: String
    private let file: URL
    private let log: (String) -> Void
    private(set) var manager: CBPeripheralManager?
    /// The epoch the core gave with its latest add or advertisement; requests arrive for it. -1 while off.
    private var liveEpoch = -1
    /// Services CoreBluetooth holds, by the core's UUID form (restored ones included).
    private var table: [String: CBMutableService] = [:]
    /// Services the core handed over before the manager was powered on, added once it is.
    private var waitingAdds: [(epoch: Int, service: CBMutableService)] = []
    /// Epoch of each add in flight, by UUID: didAdd answers with it.
    private var adding: [String: Int] = [:]
    private var advertiseToken = 0
    private var advertiseEpoch = 0
    private var waitingAdvertise: [String: Any]?
    /// Centrals that subscribed, by id: updateValue sends to one of them.
    private var centrals: [String: CBCentral] = [:]
    private var restoredServices: [CBMutableService]?
    private var restoredAdvertising = false
    private var launchedWithFile = false
    private var settled = false
    private var readyWaiters: [BleCentralRadio.Waiter] = []
    /// Requests the page answers (characteristics with flag a), by the core's request number.
    private var asked: [Int: (epoch: Int, request: CBATTRequest, read: Bool)] = [:]

    init(core: BleCore, restoreIdentifier: String, dataDirectory: URL, log: @escaping (String) -> Void) {
        self.core = core
        self.restoreIdentifier = restoreIdentifier
        self.file = dataDirectory.appendingPathComponent("ble-server.json")
        self.log = log
        super.init()
    }

    var hasManager: Bool { manager != nil }

    var stateName: String? { manager.map { BleCentralRadio.name($0.state) } }

    /// At launch: create the manager only when the server file says iOS may restore one.
    func launch() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        launchedWithFile = true
        makeManager()
    }

    @discardableResult
    func makeManager() -> CBPeripheralManager {
        if let m = manager { return m }
        let m = CBPeripheralManager(delegate: self, queue: nil, options: [
            CBPeripheralManagerOptionRestoreIdentifierKey: restoreIdentifier,
        ])
        manager = m
        return m
    }

    /// Creates the manager when needed and waits until its state is known, or until `deadline`.
    func ready(until deadline: DispatchTime) async {
        let m = makeManager()
        if m.state != .unknown { return }
        let w = BleCentralRadio.Waiter()
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

    private var on: Bool { manager?.state == .poweredOn }

    // MARK: keys

    /// The core's key of a local characteristic: one instance per service UUID, so the service number is 0.
    static func key(_ c: CBCharacteristic) -> String? {
        guard let svc = c.service else { return nil }
        var cn = 0
        for x in svc.characteristics ?? [] {
            if x === c { break }
            if x.uuid == c.uuid { cn += 1 }
        }
        return BleCore.key(BleCentralRadio.uuid(svc.uuid), 0, BleCentralRadio.uuid(c.uuid), cn)
    }

    private func resolve(_ key: String) -> CBMutableCharacteristic? {
        let p = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
        guard p.count == 4, let svc = table[p[0]], var cn = Int(p[3]) else { return nil }
        for c in svc.characteristics ?? [] where BleCentralRadio.uuid(c.uuid) == p[2] {
            if cn == 0 { return c as? CBMutableCharacteristic }
            cn -= 1
        }
        return nil
    }

    static func centralId(_ c: CBCentral) -> String { c.identifier.uuidString }

    /// ATT MTU of a central: the longest update plus the 3-byte header.
    static func mtu(_ c: CBCentral) -> Int { c.maximumUpdateValueLength + 3 }

    static func attError(_ outcome: String, read: Bool) -> CBATTError.Code {
        switch outcome {
        case "ok": return .success
        case "not_found": return .attributeNotFound
        case "not_permitted": return read ? .readNotPermitted : .writeNotPermitted
        case "invalid_offset": return .invalidOffset
        case "invalid_length": return .invalidAttributeValueLength
        case "insufficient_authentication": return .insufficientAuthentication
        case "insufficient_authorization": return .insufficientAuthorization
        case "insufficient_encryption": return .insufficientEncryption
        case "not_supported": return .requestNotSupported
        case "insufficient_resources": return .insufficientResources
        default: return .unlikelyError
        }
    }

    // MARK: GATT server

    func serviceAdd(_ epoch: Int, _ uuid: String, _ primary: Bool, _ chars: [BleObj]) -> String? {
        guard let m = manager, m.state == .poweredOn || m.state == .unknown else {
            return "unavailable Bluetooth is \(stateName ?? "unknown")"
        }
        let svc = CBMutableService(type: CBUUID(string: uuid), primary: primary)
        var list: [CBMutableCharacteristic] = []
        for c in chars {
            let f = c["flags"] as? String ?? ""
            var props: CBCharacteristicProperties = []
            var perms: CBAttributePermissions = []
            if f.contains("r") {
                props.insert(.read)
                perms.insert(f.contains("R") ? .readEncryptionRequired : .readable)
            }
            if f.contains("w") { props.insert(.write) }
            if f.contains("c") { props.insert(.writeWithoutResponse) }
            if f.contains("w") || f.contains("c") { perms.insert(f.contains("W") ? .writeEncryptionRequired : .writeable) }
            if f.contains("n") { props.insert(.notify) }
            if f.contains("i") { props.insert(.indicate) }
            // No value: a cached value would make the characteristic read-only and bypass the core's store.
            list.append(CBMutableCharacteristic(type: CBUUID(string: c["uuid"] as? String ?? ""), properties: props,
                                                value: nil, permissions: perms))
        }
        svc.characteristics = list
        liveEpoch = epoch
        if m.state == .poweredOn {
            add(epoch, svc)
        } else {
            // The manager was created after the central one and has not settled yet: add once it is on.
            waitingAdds.append((epoch, svc))
        }
        return nil
    }

    private func add(_ epoch: Int, _ svc: CBMutableService) {
        let u = BleCentralRadio.uuid(svc.uuid)
        adding[u] = epoch
        table[u] = svc
        manager?.add(svc)
    }

    func serviceRemove(_ uuid: String) {
        waitingAdds.removeAll { BleCentralRadio.uuid($0.service.uuid) == uuid }
        guard let svc = table.removeValue(forKey: uuid) else { return }
        if on { manager?.remove(svc) }
    }

    func notify(_ epoch: Int, _ packet: Int, _ central: String, _ key: String, _ data: [UInt8], _ indicate: Bool) -> String? {
        guard let m = manager, m.state == .poweredOn, epoch == liveEpoch else { return "unavailable the GATT server is closed" }
        guard let c = resolve(key) else { return "not_found the characteristic is not in the server" }
        guard let to = centrals[central] else { return "unknown_device the central is no longer subscribed" }
        // iOS sends a notification or an indication by the characteristic's properties and the subscription.
        return m.updateValue(Data(data), for: c, onSubscribedCentrals: [to]) ? nil : "full"
    }

    /// The page's answer to request `request` (or the core's unlikely when the page did not answer in time).
    /// A read's value starts at the request's own offset: CBATTRequest carries the offset itself.
    func attRespond(_ epoch: Int, _ request: Int, _ status: String, _ offset: Int, _ data: [UInt8]?) -> String? {
        guard let q = asked.removeValue(forKey: request), q.epoch == epoch, let m = manager, m.state == .poweredOn else {
            return "unavailable the request is no longer open on the radio (Bluetooth went off)"
        }
        if let d = data { q.request.value = Data(d) }
        m.respond(to: q.request, withResult: BlePeripheralRadio.attError(status, read: q.read))
        return nil
    }

    // MARK: L2CAP channels

    /// Bytes per read of a channel's input stream: a longer arrival is several l2cap_data records.
    static let l2capRead = 2048

    /// One open channel (either role): its streams run on the main run loop with this radio as delegate.
    final class Chan {
        let n: Int
        let channel: CBL2CAPChannel
        /// Bytes the output stream has not taken yet; sent as it reports space.
        var pendingOut: [UInt8] = []

        init(_ n: Int, _ channel: CBL2CAPChannel) {
            self.n = n
            self.channel = channel
        }
    }

    /// Publishes in flight, in order: didPublishL2CAPChannel answers them one by one.
    private var publishing: [(epoch: Int, t: Int)] = []
    private var chans: [Int: Chan] = [:]

    func l2capPublish(_ epoch: Int, _ t: Int, _ encrypted: Bool) -> String? {
        guard let m = manager, m.state == .poweredOn else { return "unavailable Bluetooth is \(stateName ?? "unknown")" }
        liveEpoch = epoch
        publishing.append((epoch, t))
        m.publishL2CAPChannel(withEncryption: encrypted)
        return nil
    }

    func l2capUnpublish(_ psm: Int) {
        if on { manager?.unpublishL2CAPChannel(CBL2CAPPSM(psm)) }
    }

    /// Takes an open channel as number `n`: its streams are opened on the main run loop.
    func adopt(_ n: Int, _ channel: CBL2CAPChannel) {
        let c = Chan(n, channel)
        chans[n] = c
        for s in [channel.inputStream as Stream?, channel.outputStream as Stream?] {
            guard let s = s else { continue }
            s.delegate = self
            s.schedule(in: .main, forMode: .common)
            s.open()
        }
    }

    private static func closeStreams(_ channel: CBL2CAPChannel) {
        for s in [channel.inputStream as Stream?, channel.outputStream as Stream?] {
            guard let s = s else { continue }
            s.delegate = nil
            s.close()
            s.remove(from: .main, forMode: .common)
        }
    }

    func l2capSend(_ n: Int, _ data: [UInt8]) -> String? {
        guard let c = chans[n] else { return "not_found the channel is closed" }
        c.pendingOut += data
        flush(c)
        return nil
    }

    func l2capClose(_ n: Int) {
        guard let c = chans.removeValue(forKey: n) else { return }
        BlePeripheralRadio.closeStreams(c.channel)
    }

    private func flush(_ c: Chan) {
        guard let out = c.channel.outputStream else { return }
        while !c.pendingOut.isEmpty && out.hasSpaceAvailable {
            let k = c.pendingOut.withUnsafeBufferPointer { out.write($0.baseAddress!, maxLength: $0.count) }
            if k <= 0 { break }
            c.pendingOut.removeFirst(k)
        }
    }

    /// The channel ended on the platform's side; nothing when this side closed it first.
    private func ended(_ c: Chan, _ code: String?) {
        guard chans[c.n] === c else { return }
        chans.removeValue(forKey: c.n)
        BlePeripheralRadio.closeStreams(c.channel)
        core.l2capClosed(c.n, code)
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let c = chans.values.first(where: { $0.channel.inputStream === aStream || $0.channel.outputStream === aStream }) else {
            return
        }
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var buf = [UInt8](repeating: 0, count: BlePeripheralRadio.l2capRead)
            while chans[c.n] === c && input.hasBytesAvailable {
                let k = input.read(&buf, maxLength: buf.count)
                if k <= 0 { break }
                core.l2capData(c.n, BleCore.hex(Array(buf[0..<k])))
            }
        case .hasSpaceAvailable:
            flush(c)
        case .errorOccurred:
            let e = aStream.streamError.map { $0 as NSError }
            ended(c, e.map { "error \($0.domain) \($0.code)" } ?? "error")
        case .endEncountered:
            ended(c, nil)
        default:
            break
        }
    }

    // MARK: advertiser

    func advertiseStart(_ epoch: Int, _ adv: Int, _ params: BleObj) -> String? {
        guard let m = manager, m.state == .poweredOn || m.state == .unknown else {
            return "unavailable Bluetooth is \(stateName ?? "unknown")"
        }
        // iOS advertises only service UUIDs and a local name (Apple, startAdvertising(_:)).
        var data: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: ((params["services"] as? [Any]) ?? []).compactMap { $0 as? String }.map { CBUUID(string: $0) },
        ]
        if let name = params["name"] as? String { data[CBAdvertisementDataLocalNameKey] = name }
        advertiseToken = adv
        advertiseEpoch = epoch
        liveEpoch = epoch
        if m.state == .poweredOn {
            m.startAdvertising(data)
        } else {
            waitingAdvertise = data
        }
        return nil
    }

    func advertiseStop(_ adv: Int) {
        guard adv == advertiseToken else { return }
        advertiseToken = 0
        waitingAdvertise = nil
        if on { manager?.stopAdvertising() }
    }

    // MARK: the server file

    func persist(_ snapshot: BleObj?) {
        do {
            if let s = snapshot {
                let data = try JSONSerialization.data(withJSONObject: s.plain, options: [.sortedKeys])
                // Written to a temporary file and renamed, never in place.
                try data.write(to: file, options: [.atomic])
            } else if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            log("ble-server.json not written: \((error as NSError).domain) \((error as NSError).code)")
        }
    }

    /// Moved-aside server files are kept for diagnosis, at most this many, the newest.
    static let asideKept = 3

    /// Removes moved-aside server files beyond the newest `asideKept`.
    static func pruneAside(_ dir: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("ble-server.unreadable-") && $0.hasSuffix(".json") }
        for name in asideOverflow(names) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// The moved-aside names to remove: all but the newest `asideKept`, by their time stamp.
    static func asideOverflow(_ names: [String]) -> [String] {
        func stamp(_ n: String) -> Int {
            Int(n.dropFirst("ble-server.unreadable-".count).dropLast(".json".count)) ?? 0
        }
        let newest = names.sorted { stamp($0) > stamp($1) }
        return Array(newest.dropFirst(asideKept))
    }

    /// Once the first state settled: adopt what iOS restored, or end an ordinary launch's file.
    private func settleLaunch() {
        guard launchedWithFile else { return }
        var snapshot: [String: Any]?
        var state = "absent"
        if let data = try? Data(contentsOf: file) {
            snapshot = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            state = snapshot == nil ? "unreadable" : "readable"
        } else if FileManager.default.fileExists(atPath: file.path) {
            state = "unreadable"
        }
        let restored = restoredServices != nil || restoredAdvertising
        switch BleCore.serverFileAction(state, restored: restored) {
        case "move_aside":
            let dir = file.deletingLastPathComponent()
            let aside = dir.appendingPathComponent("ble-server.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            BlePeripheralRadio.pruneAside(dir)
        case "delete":
            try? FileManager.default.removeItem(at: file)
        default:
            break
        }
        guard restored else { return }
        let services = restoredServices ?? []
        for s in services { table[BleCentralRadio.uuid(s.uuid)] = s }
        liveEpoch = core.epoch
        if restoredAdvertising { advertiseEpoch = core.epoch }
        core.serverRestored(state == "readable" ? snapshot : nil, restoredServices: services.map { BleCentralRadio.uuid($0.uuid) },
                            wasAdvertising: restoredAdvertising)
        // The core's restored advertisement token is the newest one it made.
        if restoredAdvertising { advertiseToken = core.advertisingToken }
        // Centrals that stayed subscribed while the app was gone.
        for s in services {
            for c in s.characteristics ?? [] {
                guard let mc = c as? CBMutableCharacteristic, let k = BlePeripheralRadio.key(mc) else { continue }
                for central in mc.subscribedCentrals ?? [] {
                    let id = BlePeripheralRadio.centralId(central)
                    centrals[id] = central
                    _ = core.subscription(liveEpoch, id, BlePeripheralRadio.mtu(central), k, BlePeripheralRadio.mode(mc))
                }
            }
        }
        restoredServices = nil
        restoredAdvertising = false
    }

    static func mode(_ c: CBCharacteristic) -> String {
        c.properties.contains(.indicate) && !c.properties.contains(.notify) ? "indicate" : "notify"
    }

    // MARK: CBPeripheralManagerDelegate

    /// The adapter state the extension forwards to the core (the central manager reports the same radio).
    var onState: ((String) -> Void)?

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        dispatchPrecondition(condition: .onQueue(.main))
        let s = peripheral.state
        if s != .unknown {
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume() }
        }
        if s != .poweredOn {
            // CoreBluetooth cleared the local database and stopped advertising; the core re-adds.
            liveEpoch = -1
            table = [:]
            adding = [:]
            centrals = [:]
            advertiseToken = 0
            asked = [:]
            publishing = []
        }
        if !settled && s != .unknown {
            settled = true
            settleLaunch()
        }
        if s != .unknown { onState?(BleCentralRadio.name(s)) }
        guard s == .poweredOn else { return }
        let adds = waitingAdds
        waitingAdds = []
        for (e, svc) in adds where e == core.epoch { add(e, svc) }
        if let data = waitingAdvertise, advertiseEpoch == core.epoch {
            waitingAdvertise = nil
            peripheral.startAdvertising(data)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        dispatchPrecondition(condition: .onQueue(.main))
        restoredServices = (dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService]) ?? []
        restoredAdvertising = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] != nil
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        let u = BleCentralRadio.uuid(service.uuid)
        guard let e = adding.removeValue(forKey: u) else { return }
        if error != nil { table.removeValue(forKey: u) }
        core.serviceAdded(e, u, error.map { "error \(($0 as NSError).code)" })
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard advertiseToken != 0 else { return }
        core.advertiseStarted(advertiseEpoch, advertiseToken, error.map { "error \(($0 as NSError).code)" })
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let k = BlePeripheralRadio.key(characteristic) else { return }
        let id = BlePeripheralRadio.centralId(central)
        centrals[id] = central
        let r = core.subscription(liveEpoch, id, BlePeripheralRadio.mtu(central), k, BlePeripheralRadio.mode(characteristic))
        if r != "ok" { log("subscription \(k): \(r)") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let k = BlePeripheralRadio.key(characteristic) else { return }
        _ = core.subscription(liveEpoch, BlePeripheralRadio.centralId(central), BlePeripheralRadio.mtu(central), k, nil)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        dispatchPrecondition(condition: .onQueue(.main))
        core.notifyReady(liveEpoch)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = BlePeripheralRadio.centralId(request.central)
        guard let k = BlePeripheralRadio.key(request.characteristic) else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let r = core.readRequest(liveEpoch, id, BlePeripheralRadio.mtu(request.central), k, request.offset)
        let status = r["status"] as? String ?? "unlikely"
        if status == "pending", let n = r["request"] as? Int {
            asked[n] = (liveEpoch, request, true)
            return
        }
        if status == "ok", let hex = r["hex"] as? String, let bytes = BleCore.fromHex(hex) { request.value = Data(bytes) }
        peripheral.respond(to: request, withResult: BlePeripheralRadio.attError(status, read: true))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let first = requests.first else { return }
        let id = BlePeripheralRadio.centralId(first.central)
        var reqs: [BleObj] = []
        for q in requests {
            guard let k = BlePeripheralRadio.key(q.characteristic) else {
                peripheral.respond(to: first, withResult: .attributeNotFound)
                return
            }
            reqs.append(BleCore.obj(("key", k), ("offset", q.offset), ("hex", BleCore.hex([UInt8](q.value ?? Data())))))
        }
        // iOS delivers one batch and takes one answer, for the first request (all or none).
        let r = core.writeRequests(liveEpoch, id, BlePeripheralRadio.mtu(first.central), reqs, false)
        if r.hasPrefix("pending "), let n = Int(r.dropFirst(8)) {
            asked[n] = (liveEpoch, first, false)
            return
        }
        peripheral.respond(to: first, withResult: BlePeripheralRadio.attError(r, read: false))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !publishing.isEmpty else { return }
        let p = publishing.removeFirst()
        core.l2capPublished(p.epoch, p.t, Int(PSM), error.map { "error \(($0 as NSError).domain) \(($0 as NSError).code)" })
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let ch = channel, error == nil else { return }
        let n = core.l2capIncoming(liveEpoch, Int(ch.psm), ch.peer.identifier.uuidString)
        if n >= 0 { adopt(n, ch) }
    }
}
