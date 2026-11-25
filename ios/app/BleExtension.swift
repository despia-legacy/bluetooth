import CoreBluetooth
import Foundation

/// Universal Bluetooth LE for the page: scan, connect, GATT client, GATT server, advertising and raw
/// bytes. Every decision is `BleCore`'s (shared vector table with the Android twin);
/// `BleCentralRadio` and `BlePeripheralRadio` talk to CoreBluetooth. This type owns the bridge side: route parameters, the Bluetooth authorization, one
/// reply per call, events and timers. Main actor, as NativeExtension requires; the core's
/// port is an isolated conformance (`@MainActor BlePort`), so the core runs on the main actor too.
///
/// The CBCentralManager is created only when a route needs Bluetooth (the permission prompt can
/// follow) or at launch through `restoreBluetoothCentrals` when the app is already authorized (no
/// prompt), so iOS can restore it: a scene-based app gets no launchOptions to tell a Bluetooth
/// relaunch (Apple, "Central Manager State Restoration Options"). The
/// CBPeripheralManager is created only by a server route, or at launch when `ble-server.json`
/// exists (iOS restores a peripheral manager only when it is created again during launch). `state`
/// without `prompt` never creates a manager before the app is authorized, so it never prompts.
///
/// Each route that reaches the core gets a call number; the core answers each exactly once through
/// `reply`, which resumes that route's continuation. A route that timed out while it waited for the
/// manager starts nothing (`call.isActive`).
@MainActor
final class BleExtension: NSObject, NativeExtension, @MainActor BlePort {
    private var ctx: NativeExtContext!
    private var core: BleCore!
    private var radio: BleCentralRadio!
    private var server: BlePeripheralRadio!
    private var nextCall = 0
    private var calls: [Int: Waiting] = [:]
    private var inBackground = false
    private var mirror: BleServerMirror!
    /// The disk-durable journal: `ble/journal.jsonl` (this run) and `ble/journal-prev.jsonl`.
    private var journalFile: URL!
    private var persistPending = false
    static let persistMs = 250

    private struct Waiting {
        let call: NativeExtCall
        let continuation: CheckedContinuation<NativeExtResult, Never>
    }

    required override init() { super.init() }

    func didLaunch(_ context: NativeExtContext) {
        ctx = context
        let run = UUID().uuidString
        core = BleCore(port: self, platform: "ios", run: run)
        mirror = BleServerMirror(dataDirectory: context.dataDirectory, log: { [weak context] in context?.log($0) })
        openJournal(run)
        radio = BleCentralRadio(core: core, restoreIdentifier: context.bluetoothRestoreIdentifier("main"))
        server = BlePeripheralRadio(core: core, restoreIdentifier: context.bluetoothRestoreIdentifier("server"),
                                    dataDirectory: context.dataDirectory, log: { [weak context] in context?.log($0) })
        // Both managers watch the same radio; whichever settles tells the core (it ignores a repeat).
        server.onState = { [weak self] state in self?.core.adapter(state) }
        radio.onL2capOpened = { [weak self] n, channel, code in self?.l2capOpened(n, channel, code) }
        server.launch()
    }

    /// Launch: the previous process's journal becomes `events?run=<previousRun>`; this run gets a
    /// fresh file. Reading a file starts no manager.
    private func openJournal(_ run: String) {
        let dir = ctx.dataDirectory.appendingPathComponent("ble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journalFile = dir.appendingPathComponent("journal.jsonl")
        let prev = dir.appendingPathComponent("journal-prev.jsonl")
        if let text = try? String(contentsOf: journalFile, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if let head = lines.first, let h = BleExtension.parse(String(head)) as? [String: Any], let prevRun = h["run"] as? String {
                // A torn last line (the process died mid-write) is skipped; everything before it stands.
                let records = lines.dropFirst().compactMap { BleExtension.parse(String($0)).map(BleExtension.record) }
                core.loadPrevious(prevRun, records)
            }
            try? FileManager.default.removeItem(at: prev)
            try? FileManager.default.moveItem(at: journalFile, to: prev)
        }
        writeJournal(BleCore.json(BleCore.obj(("run", run))) + "\n", append: false)
    }

    private static func parse(_ line: String) -> Any? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    /// A journal record from its file form, top-level keys in the journal's own order.
    private static func record(_ v: Any) -> BleObj {
        let o = BleObj()
        guard let d = v as? [String: Any] else { return o }
        for k in ["seq", "t", "event", "data"] where d[k] != nil { o[k] = value(d[k]!) }
        for k in d.keys.sorted() where o[k] == nil { o[k] = value(d[k]!) }
        return o
    }

    private static func value(_ v: Any) -> Any {
        if let d = v as? [String: Any] {
            let o = BleObj()
            for k in d.keys.sorted() { o[k] = value(d[k]!) }
            return o
        }
        if let l = v as? [Any] { return l.map { value($0) } }
        return v
    }

    private func writeJournal(_ text: String, append: Bool) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            if append, let h = try? FileHandle(forWritingTo: journalFile) {
                defer { try? h.close() }
                try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: journalFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } catch {
            ctx.log("journal file: \(error.localizedDescription)")
        }
    }

    /// Appends the records since the last call, or rewrites the bounded window (BleCore.journalToPersist).
    private func persistJournal() {
        persistPending = false
        guard let j = core.journalToPersist() else { return }
        var text = j.rewrite ? BleCore.json(BleCore.obj(("run", core.run))) + "\n" : ""
        for r in j.records { text += BleCore.json(r) + "\n" }
        writeJournal(text, append: !j.rewrite)
    }

    /// Every launch (the runtime cannot tell a Bluetooth relaunch in a scene-based app): recreate the
    /// central with its restore identifier when that cannot prompt; willRestoreState then hands back
    /// what iOS kept, and with nothing kept the manager only reports its state.
    func restoreBluetoothCentrals(_ identifiers: [String]) {
        guard identifiers.contains(ctx.bluetoothRestoreIdentifier("main")),
              CBManager.authorization == .allowedAlways else { return }
        _ = radio.makeManager()
    }

    func sceneDidChange(_ phase: NativeExtScenePhase) {
        switch phase {
        case .didEnterBackground: inBackground = true
        case .willEnterForeground, .didBecomeActive: inBackground = false
        case .willResignActive: return
        }
        core.background(inBackground)
    }

    /// Routes that read the core's own state and never touch the radio.
    private static let local: Set<String> = ["events", "devices", "links", "scan_stop", "disconnect", "services",
                                             "service_remove", "value_set", "advertise_stop", "centrals", "central_drop",
                                             "keep_alive", "priority", "phy", "bond", "bonds", "respond", "l2cap_unpublish",
                                             "l2cap_send", "l2cap_close", "l2cap_channels", "advertise_set_start",
                                             "advertise_set_stop"]
    private static let radioRoutes: Set<String> = ["scan_start", "connect", "discover", "read", "write", "subscribe",
                                                   "unsubscribe", "rssi", "mtu", "raw", "system_devices", "connection_events",
                                                   "l2cap_open"]
    /// Routes of the GATT server and the advertiser: they need the peripheral manager.
    private static let serverRoutes: Set<String> = ["service_add", "notify", "advertise_start", "l2cap_publish"]

    func handle(_ call: NativeExtCall) async -> NativeExtResult {
        mirror.pump()
        if call.route == "state" { return await state(call) }
        if BleExtension.local.contains(call.route) { return await run(call) }
        if BleExtension.serverRoutes.contains(call.route) {
            await server.ready(until: call.deadline)
            guard call.isActive else { return .error(code: "timeout", message: "the peripheral manager was not ready before the route timed out") }
        } else {
            guard BleExtension.radioRoutes.contains(call.route) else { return .error(code: "not_registered", message: call.route) }
            await radio.ready(until: call.deadline)
            guard call.isActive else { return .error(code: "timeout", message: "Bluetooth was not ready before the route timed out") }
        }
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            return .error(code: "permission_denied", message: "Bluetooth access was denied")
        }
        return await run(call)
    }

    private func state(_ call: NativeExtCall) async -> NativeExtResult {
        let prompt = call.params["prompt"] as? Bool ?? false
        if prompt || radio.hasManager || CBManager.authorization == .allowedAlways {
            if server.hasManager && !radio.hasManager && !prompt {
                await server.ready(until: call.deadline)
                guard call.isActive else { return .error(code: "timeout", message: "state timed out") }
            } else {
                await radio.ready(until: call.deadline)
                guard call.isActive else { return .error(code: "timeout", message: "state timed out") }
            }
        }
        // Either manager reports the one radio; the central's name is used once it exists.
        let name = radio.hasManager ? radio.stateName : (server.stateName ?? radio.stateName)
        let data = BleCore.obj(("state", name),
                               ("authorization", BleCentralRadio.authorizationName(CBManager.authorization)))
        data.putAll(core.stateFields())
        data["server"] = mirror.status()
        return .ok(data.plain)
    }

    /// Hands the route to the core and waits for its one reply.
    private func run(_ call: NativeExtCall) async -> NativeExtResult {
        nextCall += 1
        let c = nextCall
        return await withCheckedContinuation { (k: CheckedContinuation<NativeExtResult, Never>) in
            calls[c] = Waiting(call: call, continuation: k)
            dispatch(c, call)
        }
    }

    private func dispatch(_ c: Int, _ call: NativeExtCall) {
        let p = call.params
        let id = p["id"] as? String
        func int(_ k: String, _ d: Int) -> Int { p[k] as? Int ?? d }
        func flag(_ k: String, _ d: Bool) -> Bool { p[k] as? Bool ?? d }
        func str(_ k: String) -> String? { p[k] as? String }
        switch call.route {
        case "events": core.events(c, int("after", 0), int("max", 200), run: str("run"))
        case "scan_start":
            let options = BleObj()
            for k in BleCore.scanOptionKeys { if let v = p[k] { options[k] = v } }
            core.scanStart(c, str("services"), int("seconds", 0), flag("duplicates", false), str("mode") ?? "balanced",
                           inBackground, names: str("names"), manufacturerId: int("manufacturer_id", -1),
                           manufacturerHex: str("manufacturer_hex"), options: options)
        case "scan_stop": core.scanStop(c)
        case "devices": core.devices(c)
        case "connect":
            if let id = id {
                if let url = str("server") { mirror.watchState(id, url) }
                _ = radio.setConnectOptions(id, p)
            }
            core.connect(c, id, flag("auto", false), int("seconds", 10))
        case "raw": core.raw(c, id, str("hex"), str("b64"), str("text"), flag("response", true))
        case "priority": core.priority(c, id, str("level") ?? "balanced")
        case "phy": core.phy(c, id, str("tx"), str("rx"), str("coded") ?? "none")
        case "bond", "bonds":
            reply(c, false, "platform_limit", "iOS has no API to start, list or remove a bond: the system pairs when a "
                  + "peripheral requires encryption for an attribute the app reads or writes (CoreBluetooth)", nil)
        case "system_devices":
            guard let list = BleCore.uuidList(str("services")), !list.isEmpty else {
                reply(c, false, "bad_value", "iOS lists system-connected peripherals by service: give services (1 to 20 UUIDs)", nil)
                return
            }
            if let devices = radio.systemDevices(list) {
                reply(c, true, nil, nil, BleCore.obj(("devices", devices)))
            } else {
                reply(c, false, "unavailable", "Bluetooth is \(radio.stateName)", nil)
            }
        case "connection_events":
            guard let list = BleCore.uuidList(str("services")) else {
                reply(c, false, "bad_value", "services must be up to 20 UUIDs", nil)
                return
            }
            let ids = (str("ids") ?? "").split(separator: ",").map(String.init)
            if let err = radio.connectionEvents(list, ids) {
                let sp = err.firstIndex(of: " ") ?? err.endIndex
                reply(c, false, String(err[..<sp]), sp < err.endIndex ? String(err[err.index(after: sp)...]) : err, nil)
            } else {
                reply(c, true, nil, nil, BleCore.obj(("services", list as [Any]), ("ids", ids as [Any]),
                                                 ("applied", BleCore.obj(("services", true), ("ids", true)))))
            }
        case "disconnect": core.disconnect(c, id)
        case "links": core.links(c)
        case "discover": core.discover(c, id)
        case "read":
            core.read(c, id, str("service"), int("service_n", 0), str("char"), int("char_n", 0), str("descriptor"))
        case "write":
            core.write(c, id, str("service"), int("service_n", 0), str("char"), int("char_n", 0), str("descriptor"),
                       str("hex"), str("b64"), flag("response", true), text: str("text"))
        case "subscribe", "unsubscribe":
            if let id = id, let su = BleCore.uuid(str("service")), let cu = BleCore.uuid(str("char")) {
                let k = BleCore.key(su, int("service_n", 0), cu, int("char_n", 0))
                if call.route == "unsubscribe" { mirror.unwatchData(id, k) }
                else if let url = str("server") { mirror.watchData(id, k, url) }
            }
            core.subscribe(c, id, str("service"), int("service_n", 0), str("char"), int("char_n", 0),
                           call.route == "subscribe")
        case "rssi": core.rssi(c, id)
        case "mtu": core.mtu(c, id, int("size", BleCore.mtuRequest))
        case "service_add": core.serviceAdd(c, str("uuid"), flag("primary", true), str("chars"))
        case "service_remove": core.serviceRemove(c, str("uuid"))
        case "services": core.servicesList(c)
        case "value_set":
            core.valueSet(c, str("service"), str("char"), int("char_n", 0), str("hex"), str("b64"), text: str("text"))
        case "notify":
            core.notify(c, str("service"), str("char"), int("char_n", 0), str("hex"), str("b64"), str("central"),
                        text: str("text"))
        case "advertise_start":
            core.advertiseStart(c, str("services"), str("name"), int("manufacturer_id", -1), str("manufacturer_hex"),
                                str("service_data_uuid"), str("service_data_hex"), flag("connectable", true),
                                str("mode") ?? "balanced", int("seconds", 0), txPower: str("tx_power"),
                                includeTxPower: p["include_tx_power"] as? Bool)
        case "advertise_stop": core.advertiseStop(c)
        case "centrals": core.centrals(c)
        case "central_drop": core.centralDrop(c, str("central"))
        case "keep_alive": core.keepAlive(c, flag("enabled", false), BleExtension.backgroundModes)
        case "respond":
            core.respond(c, int("request", 0), str("status"), str("hex"), str("b64"), str("text"), int("offset", -1))
        case "l2cap_publish": core.l2capPublish(c, flag("encrypted", true))
        case "l2cap_unpublish": core.l2capUnpublish(c, int("psm", 0))
        case "l2cap_open": core.l2capOpen(c, id, int("psm", 0), flag("encrypted", true), int("seconds", 0))
        case "l2cap_send": core.l2capSend(c, int("channel", 0), str("hex"), str("b64"), str("text"))
        case "l2cap_close": core.l2capClose(c, int("channel", 0))
        case "l2cap_channels": core.l2capChannels(c)
        case "advertise_set_start":
            let raw = BleObj()
            for k in p.keys.sorted() { raw[k] = p[k] }
            core.advertiseSetStart(c, raw)
        case "advertise_set_stop": core.advertiseSetStop(c, int("set", 0))
        default: reply(c, false, "not_registered", call.route, nil)
        }
    }

    // MARK: BlePort: radio

    func scanStart(_ scan: Int, _ services: [String], _ duplicates: Bool, _ mode: String, _ options: BleObj) -> String? {
        radio.scanStart(scan, services, duplicates, mode, options)
    }

    func writable(_ id: String, _ gen: Int, _ withResponse: Bool) -> String? { radio.writable(id, gen, withResponse) }

    func scanStop(_ scan: Int) { radio.scanStop(scan) }

    func connect(_ id: String, _ gen: Int, _ auto: Bool, _ background: Bool) -> String? {
        radio.connect(id, gen, auto, background)
    }

    func close(_ id: String, _ gen: Int) -> Bool { radio.close(id, gen) }

    func release(_ id: String, _ gen: Int) { radio.release(id, gen) }

    func op(_ id: String, _ gen: Int, _ op: Int, _ kind: String, _ key: String?, _ descriptor: String?,
            _ data: [UInt8]?, _ arg: Int) -> String? {
        radio.op(id, gen, op, kind, key, descriptor, data, arg)
    }

    func serviceAdd(_ epoch: Int, _ uuid: String, _ primary: Bool, _ chars: [BleObj]) -> String? {
        server.serviceAdd(epoch, uuid, primary, chars)
    }

    func serviceRemove(_ uuid: String) { server.serviceRemove(uuid) }

    func advertiseStart(_ epoch: Int, _ adv: Int, _ params: BleObj) -> String? { server.advertiseStart(epoch, adv, params) }

    func advertiseStop(_ adv: Int) { server.advertiseStop(adv) }

    func notify(_ epoch: Int, _ packet: Int, _ central: String, _ key: String, _ data: [UInt8], _ indicate: Bool) -> String? {
        server.notify(epoch, packet, central, key, data, indicate)
    }

    /// iOS has no API to drop a remote central; the core answers `platform_limit` before this is reached.
    func centralDrop(_ central: String) {}

    /// Android only (the keep-alive service); iOS keeps links in the background by its background modes.
    func keepAlive(_ start: Bool, _ hold: Int) -> String? { nil }

    func persist(_ snapshot: BleObj?) { server.persist(snapshot) }

    func attRespond(_ epoch: Int, _ request: Int, _ status: String, _ offset: Int, _ data: [UInt8]?) -> String? {
        server.attRespond(epoch, request, status, offset, data)
    }

    func l2capPublish(_ epoch: Int, _ t: Int, _ encrypted: Bool) -> String? { server.l2capPublish(epoch, t, encrypted) }

    func l2capUnpublish(_ psm: Int) { server.l2capUnpublish(psm) }

    /// The epoch of each central-role channel being opened: didOpen reports it to the core.
    private var l2capEpochs: [Int: Int] = [:]

    /// iOS takes the channel's security from the peripheral's published channel: openL2CAPChannel has no option.
    func l2capOpen(_ epoch: Int, _ channel: Int, _ id: String, _ psm: Int, _ encrypted: Bool) -> String? {
        if let err = radio.l2capOpen(channel, id, psm) { return err }
        l2capEpochs[channel] = epoch
        return nil
    }

    /// A central-role channel opened (or failed); one the core already gave up on is let go.
    private func l2capOpened(_ n: Int, _ channel: CBL2CAPChannel?, _ code: String?) {
        guard let e = l2capEpochs.removeValue(forKey: n) else { return }
        if let ch = channel { server.adopt(n, ch) }
        core.l2capOpened(e, n, code)
    }

    func l2capSend(_ channel: Int, _ data: [UInt8]) -> String? { server.l2capSend(channel, data) }

    func l2capClose(_ channel: Int) {
        l2capEpochs.removeValue(forKey: channel)
        server.l2capClose(channel)
    }

    /// Not reached: the core answers platform_limit on iOS (BleCore.advSetLimit) before the port.
    func advertiseSetStart(_ epoch: Int, _ set: Int, _ params: BleObj) -> String? {
        "platform_limit " + BleCore.advSetLimit
    }

    func advertiseSetStop(_ set: Int) {}

    /// Whether this build declares both Bluetooth background modes (the manifest's info_plist rows).
    static var backgroundModes: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("bluetooth-central") && modes.contains("bluetooth-peripheral")
    }

    // MARK: BlePort: bridge

    func timer(_ kind: String, _ token: Int, _ ms: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            self?.core.timer(kind, token)
        }
    }

    func reply(_ call: Int, _ ok: Bool, _ code: String?, _ message: String?, _ data: BleObj?) {
        guard let w = calls.removeValue(forKey: call) else { return }
        w.continuation.resume(returning: ok ? .ok(data?.plain ?? [:]) : .error(code: code ?? "handler_error", message: message ?? ""))
    }

    func emit(_ event: String, _ data: BleObj) {
        ctx.emit(event, data.plain)
        mirror.onEvent(event, data, background: inBackground)
        if !persistPending {
            persistPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(BleExtension.persistMs) * 1_000_000)
                self?.persistJournal()
            }
        }
    }

    func isActive(_ call: Int) -> Bool { calls[call]?.call.isActive ?? false }

    func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func stale(_ what: String) { ctx.log("stale \(what)") }
}
