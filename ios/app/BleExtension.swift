import CoreBluetooth
import Foundation

/// Universal Bluetooth LE for the page: scan, connect, GATT client, GATT server, advertising and raw
/// bytes. Every decision is `BleCore`'s (shared vector table with the Android twin);
/// `BleCentralRadio` and `BlePeripheralRadio` talk to CoreBluetooth. This type owns the bridge side: route parameters, the Bluetooth authorization, one
/// reply per call, events and timers. Main actor, as NativeExtension requires; the core's
/// port is an isolated conformance (`@MainActor BlePort`), so the core runs on the main actor too.
///
/// The CBCentralManager is created only when a route needs Bluetooth (the permission prompt can
/// follow) or when iOS relaunched the app to restore it (`restoreBluetoothCentrals`). The
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

    private struct Waiting {
        let call: NativeExtCall
        let continuation: CheckedContinuation<NativeExtResult, Never>
    }

    required override init() { super.init() }

    func didLaunch(_ context: NativeExtContext) {
        ctx = context
        core = BleCore(port: self, platform: "ios", run: UUID().uuidString)
        radio = BleCentralRadio(core: core, restoreIdentifier: context.bluetoothRestoreIdentifier("main"))
        server = BlePeripheralRadio(core: core, restoreIdentifier: context.bluetoothRestoreIdentifier("server"),
                                    dataDirectory: context.dataDirectory, log: { [weak context] in context?.log($0) })
        // Both managers watch the same radio; whichever settles tells the core (it ignores a repeat).
        server.onState = { [weak self] state in self?.core.adapter(state) }
        server.launch()
    }

    func restoreBluetoothCentrals(_ identifiers: [String]) {
        guard identifiers.contains(ctx.bluetoothRestoreIdentifier("main")) else { return }
        radio.makeManager()
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
                                             "keep_alive"]
    private static let radioRoutes: Set<String> = ["scan_start", "connect", "discover", "read", "write", "subscribe",
                                                   "unsubscribe", "rssi", "mtu"]
    /// Routes of the GATT server and the advertiser: they need the peripheral manager.
    private static let serverRoutes: Set<String> = ["service_add", "notify", "advertise_start"]

    func handle(_ call: NativeExtCall) async -> NativeExtResult {
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
        case "events": core.events(c, int("after", 0), int("max", 200))
        case "scan_start":
            core.scanStart(c, str("services"), int("seconds", 0), flag("duplicates", false), str("mode") ?? "balanced",
                           inBackground)
        case "scan_stop": core.scanStop(c)
        case "devices": core.devices(c)
        case "connect": core.connect(c, id, flag("auto", false), int("seconds", 10))
        case "disconnect": core.disconnect(c, id)
        case "links": core.links(c)
        case "discover": core.discover(c, id)
        case "read":
            core.read(c, id, str("service"), int("service_n", 0), str("char"), int("char_n", 0), str("descriptor"))
        case "write":
            core.write(c, id, str("service"), int("service_n", 0), str("char"), int("char_n", 0), str("descriptor"),
                       str("hex"), str("b64"), flag("response", true))
        case "subscribe", "unsubscribe":
            core.subscribe(c, id, str("service"), int("service_n", 0), str("char"), int("char_n", 0),
                           call.route == "subscribe")
        case "rssi": core.rssi(c, id)
        case "mtu": core.mtu(c, id, int("size", BleCore.mtuRequest))
        case "service_add": core.serviceAdd(c, str("uuid"), flag("primary", true), str("chars"))
        case "service_remove": core.serviceRemove(c, str("uuid"))
        case "services": core.servicesList(c)
        case "value_set": core.valueSet(c, str("service"), str("char"), int("char_n", 0), str("hex"), str("b64"))
        case "notify":
            core.notify(c, str("service"), str("char"), int("char_n", 0), str("hex"), str("b64"), str("central"))
        case "advertise_start":
            core.advertiseStart(c, str("services"), str("name"), int("manufacturer_id", -1), str("manufacturer_hex"),
                                str("service_data_uuid"), str("service_data_hex"), flag("connectable", true),
                                str("mode") ?? "balanced", int("seconds", 0))
        case "advertise_stop": core.advertiseStop(c)
        case "centrals": core.centrals(c)
        case "central_drop": core.centralDrop(c, str("central"))
        case "keep_alive": core.keepAlive(c, flag("enabled", false), BleExtension.backgroundModes)
        default: reply(c, false, "not_registered", call.route, nil)
        }
    }

    // MARK: BlePort: radio

    func scanStart(_ scan: Int, _ services: [String], _ duplicates: Bool, _ mode: String) -> String? {
        radio.scanStart(scan, services, duplicates, mode)
    }

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

    func emit(_ event: String, _ data: BleObj) { ctx.emit(event, data.plain) }

    func isActive(_ call: Int) -> Bool { calls[call]?.call.isActive ?? false }

    func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func stale(_ what: String) { ctx.log("stale \(what)") }
}
