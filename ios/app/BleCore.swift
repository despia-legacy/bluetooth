import Foundation

/// Every decision of the BLE extension, as one state machine on the main thread. Foundation only:
/// no CoreBluetooth, so the same test table runs against this type
/// with swiftc and against its Java twin BleCore.java. The radio and extension files only translate
/// platform callbacks into the inputs below and execute what the `BlePort` is asked to do.
///
/// Tokens. `gen` names one connection attempt, `scan` one scan, `op` one GATT operation step; all
/// come from counters that never repeat in a process. Every radio callback and every timer carries
/// its token back; one whose token is not current changes nothing, replies to nothing and is counted
/// as a stale drop (rules 1, 2 and 7 of the design).
///
/// Port calls never call back into the core: what the platform confirms at once comes back as the
/// return value (an error text, or `true` for a close that needs no callback).
protocol BlePort: AnyObject {
    /// Start a scan. nil when the platform accepted it, else "code message".
    func scanStart(_ scan: Int, _ services: [String], _ duplicates: Bool, _ mode: String) -> String?
    func scanStop(_ scan: Int)
    /// Start connection attempt `gen`. `background`: an automatic reconnect.
    func connect(_ id: String, _ gen: Int, _ auto: Bool, _ background: Bool) -> String?
    /// Begin closing `gen`. True when the platform confirmed the close now (no callback follows).
    func close(_ id: String, _ gen: Int) -> Bool
    /// The close of `gen` was not confirmed in time: release the platform object without waiting.
    func release(_ id: String, _ gen: Int)
    /// Hand one GATT step to the platform (kinds as BleCore.java). nil when accepted, else "code message".
    func op(_ id: String, _ gen: Int, _ op: Int, _ kind: String, _ key: String?, _ descriptor: String?,
            _ data: [UInt8]?, _ arg: Int) -> String?
    func timer(_ kind: String, _ token: Int, _ ms: Int)
    func reply(_ call: Int, _ ok: Bool, _ code: String?, _ message: String?, _ data: BleObj?)
    func emit(_ event: String, _ data: BleObj)
    func isActive(_ call: Int) -> Bool
    func now() -> Int
    /// A callback or timer for a token that is no longer current was dropped.
    func stale(_ what: String)

    // Peripheral role (kinds and answers as BleCore.java's Port). Server and advertiser callbacks
    // come back with the epoch they were made in.
    func serviceAdd(_ epoch: Int, _ uuid: String, _ primary: Bool, _ chars: [BleObj]) -> String?
    func serviceRemove(_ uuid: String)
    func advertiseStart(_ epoch: Int, _ adv: Int, _ params: BleObj) -> String?
    func advertiseStop(_ adv: Int)
    /// nil: handed over now; "pending": notifySent follows; "full": retry after notifyReady; else "code message".
    func notify(_ epoch: Int, _ packet: Int, _ central: String, _ key: String, _ data: [UInt8], _ indicate: Bool) -> String?
    func centralDrop(_ central: String)
    func keepAlive(_ start: Bool, _ hold: Int) -> String?
    /// iOS: write the server snapshot to ble-server.json (nil: delete the file).
    func persist(_ snapshot: BleObj?)
}

/// A JSON object that keeps insertion order (the canonical vector form, shared with the Java twin).
final class BleObj {
    private(set) var keys: [String] = []
    private var values: [String: Any] = [:]

    init(_ pairs: [(String, Any)] = []) {
        for (k, v) in pairs { self[k] = v }
    }

    subscript(key: String) -> Any? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    func putAll(_ other: BleObj) {
        for k in other.keys { self[k] = other[k] }
    }

    func copy() -> BleObj {
        let o = BleObj()
        o.putAll(self)
        return o
    }

    /// Plain Foundation form for NativeExtResult and NativeExtContext.emit.
    var plain: [String: Any] {
        var out: [String: Any] = [:]
        for k in keys { out[k] = BleObj.plainValue(values[k]!) }
        return out
    }

    static func plainValue(_ v: Any) -> Any {
        if let o = v as? BleObj { return o.plain }
        if let l = v as? [Any] { return l.map { plainValue($0) } }
        return v
    }
}

final class BleCore {
    static let writeMax = 512
    static let queueMax = 64
    static let opMs = 10000
    static let closeMs = 2000
    /// A connect's timeout when no call gave one (the bridge's `connect` default), in ms.
    static let connectDefaultMs = 10_000
    static let flushMs = 50
    static let batchMax = 100
    static let journalRecords = 2000
    static let journalBytes = 1 << 20
    static let devicesMax = 200
    static let mtuRequest = 517

    let port: BlePort
    let android: Bool
    let run: String
    private(set) var epoch = 1
    private(set) var adapterState = "unknown"
    private var nextGen = 0, nextScan = 0, nextOp = 0, nextSeq = 0, nextPending = 0
    private(set) var staleDrops = 0
    private var links: [String: Link] = [:]
    private var linkOrder: [String] = []
    private var closing: [String: Closing] = [:]
    private var closingOrder: [String] = []
    private var autoWhenOn: [(String, [String])] = []
    private(set) var scan = 0
    private var lastScan = 0
    private var filtered = false
    private var devices: [String: BleObj] = [:]
    private var deviceOrder: [String] = []
    private var pendingDevices: [Any] = []
    private var journal: [(seq: Int, t: Int, event: String, data: BleObj, size: Int)] = []
    private var journalHead = 0
    private var journalSize = 0
    private(set) var dropped = 0
    private var pendingValues: [BleObj] = []
    private var flushScheduled = false

    final class Link {
        let id: String
        let gen: Int
        var state = "connecting"
        var auto = false
        var background = false
        var mtu = 23
        var connectCall = -1
        /// The token of the timer bounding an attempt no fresh connect started (restored or adopted).
        var pendingTimer = 0
        var closed = false
        var queue: [Op] = []
        var inFlight: Op?
        var wanted: [String] = []
        var subs: [(String, String)] = []
        var resubscribed = 0, failed = 0

        init(_ id: String, _ gen: Int) {
            self.id = id
            self.gen = gen
        }

        func setSub(_ k: String, _ mode: String) {
            if let i = subs.firstIndex(where: { $0.0 == k }) { subs[i].1 = mode } else { subs.append((k, mode)) }
        }

        func addWanted(_ k: String) {
            if !wanted.contains(k) { wanted.append(k) }
        }
    }

    final class Op {
        var op = 0
        let call: Int
        let kind: String
        var key: String?
        var descriptor: String?
        var data: [UInt8]?
        var arg = 0
        var chunk = 0, chunks = 0
        var `internal` = false

        init(_ call: Int, _ kind: String) {
            self.call = call
            self.kind = kind
        }
    }

    final class Closing {
        let gen: Int
        var disconnectCall = -1
        var reconnect = false
        var wanted: [String] = []
        var waiter: Waiter?

        init(_ gen: Int) { self.gen = gen }
    }

    struct Waiter {
        let call: Int
        let auto: Bool
        let seconds: Int
        let token: Int
    }

    init(port: BlePort, platform: String, run: String) {
        self.port = port
        self.android = platform == "android"
        self.run = run
    }

    // MARK: codec

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func hex(_ b: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(b.count * 2)
        for x in b {
            out.append(hexDigits[Int(x >> 4)])
            out.append(hexDigits[Int(x & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func nibble(_ c: UInt8) -> Int {
        switch c {
        case 48...57: return Int(c) - 48
        case 97...102: return Int(c) - 87
        case 65...70: return Int(c) - 55
        default: return -1
        }
    }

    /// Hex digits only, even length; nil otherwise.
    static func fromHex(_ s: String?) -> [UInt8]? {
        guard let s = s else { return nil }
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            let hi = nibble(u[i]), lo = nibble(u[i + 1])
            if hi < 0 || lo < 0 { return nil }
            out.append(UInt8((hi << 4) | lo))
            i += 2
        }
        return out
    }

    private static func sextet(_ c: UInt8) -> Int {
        switch c {
        case 65...90: return Int(c) - 65
        case 97...122: return Int(c) - 71
        case 48...57: return Int(c) + 4
        case 43, 45: return 62
        case 47, 95: return 63
        default: return -1
        }
    }

    /// Standard or URL-safe base64, padding optional; nil when malformed.
    static func fromB64(_ s: String?) -> [UInt8]? {
        guard let s = s else { return nil }
        let u = Array(s.utf8)
        var end = u.count
        var pad = 0
        while end > 0 && u[end - 1] == 61 && pad < 2 {
            end -= 1
            pad += 1
        }
        if pad > 0 && u.count % 4 != 0 { return nil }
        if end % 4 == 1 { return nil }
        var out = [UInt8]()
        var acc = 0, bits = 0
        for i in 0..<end {
            let v = sextet(u[i])
            if v < 0 { return nil }
            acc = ((acc << 6) | v) & 0xffffff
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xff))
            }
        }
        // Leftover bits must be zero (canonical encoding).
        if acc & ((1 << bits) - 1) != 0 { return nil }
        return out
    }

    static let base = "-0000-1000-8000-00805f9b34fb"

    private static func allHex(_ s: String) -> Bool {
        s.utf8.allSatisfy { nibble($0) >= 0 }
    }

    /// 16-bit, 32-bit or dashed 128-bit UUID, any case; lower-case 128-bit, or nil.
    static func uuid(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let l = s.lowercased()
        if l.utf8.count == 4 && allHex(l) { return "0000" + l + base }
        if l.utf8.count == 8 && allHex(l) { return l + base }
        let u = Array(l.utf8)
        guard u.count == 36 else { return nil }
        for i in 0..<36 {
            let dash = i == 8 || i == 13 || i == 18 || i == 23
            if dash ? u[i] != 45 : nibble(u[i]) < 0 { return nil }
        }
        return l
    }

    /// Comma-separated UUIDs, at most 20; an empty or missing list is empty; nil when malformed.
    static func uuidList(_ s: String?) -> [String]? {
        var out: [String] = []
        guard let s = s, !s.isEmpty else { return out }
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            guard let u = uuid(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            if !out.contains(u) { out.append(u) }
        }
        return out.count > 20 ? nil : out
    }

    /// iOS: a peripheral identifier (UUID). Android: a MAC in the form checkBluetoothAddress accepts.
    static func isId(_ id: String?, _ platform: String) -> Bool {
        guard let id = id else { return false }
        if platform == "android" {
            let u = Array(id.utf8)
            guard u.count == 17 else { return false }
            for i in 0..<17 {
                let c = u[i]
                if i % 3 == 2 ? c != 58 : !((48...57).contains(c) || (65...70).contains(c)) { return false }
            }
            return true
        }
        return id.utf8.count == 36 && uuid(id) != nil
    }

    /// Exactly one of hex and b64 decoded; nil when none, both, or malformed.
    static func bytes(_ hex: String?, _ b64: String?) -> [UInt8]? {
        if (hex == nil) == (b64 == nil) { return nil }
        return hex != nil ? fromHex(hex) : fromB64(b64)
    }

    /// The characteristic key used in replies, records and subscriptions.
    static func key(_ service: String, _ sn: Int, _ chr: String, _ cn: Int) -> String {
        "\(service)#\(sn)/\(chr)#\(cn)"
    }

    /// Canonical JSON with keys in insertion order: the vector form, shared with the Java twin.
    static func json(_ v: Any?) -> String {
        var b = ""
        json(&b, v)
        return b
    }

    private static func json(_ b: inout String, _ v: Any?) {
        guard let v = v, !(v is NSNull) else {
            b += "null"
            return
        }
        if let x = v as? Bool {
            b += x ? "true" : "false"
        } else if let x = v as? Int {
            b += String(x)
        } else if let s = v as? String {
            b += "\""
            for c in s.unicodeScalars {
                if c == "\"" || c == "\\" {
                    b += "\\" + String(c)
                } else if c.value < 0x20 {
                    b += String(format: "\\u%04x", c.value)
                } else {
                    b.unicodeScalars.append(c)
                }
            }
            b += "\""
        } else if let o = v as? BleObj {
            b += "{"
            for (i, k) in o.keys.enumerated() {
                if i > 0 { b += "," }
                json(&b, k)
                b += ":"
                json(&b, o[k])
            }
            b += "}"
        } else if let l = v as? [Any] {
            b += "["
            for (i, x) in l.enumerated() {
                if i > 0 { b += "," }
                json(&b, x)
            }
            b += "]"
        } else if let l = v as? [String] {
            json(&b, l as [Any])
        } else {
            preconditionFailure("no JSON form for \(type(of: v))")
        }
    }

    static func obj(_ pairs: (String, Any)...) -> BleObj {
        BleObj(pairs)
    }

    /// The platform's own error codes, by domain: the constant's name and a readable reason. From
    /// the iOS SDK's CBError.h (CBErrorDomain) and the android-36 platform's BluetoothGatt constants;
    /// a code with no public name (Android's 133, for one) keeps no name and its radio reason.
    static let errorNames: [String: [Int: (String, String)]] = [
        "CBErrorDomain": [
            0: ("CBErrorUnknown", "unknown"),
            1: ("CBErrorInvalidParameters", "invalid_parameters"),
            2: ("CBErrorInvalidHandle", "invalid_handle"),
            3: ("CBErrorNotConnected", "not_connected"),
            4: ("CBErrorOutOfSpace", "out_of_space"),
            5: ("CBErrorOperationCancelled", "operation_cancelled"),
            6: ("CBErrorConnectionTimeout", "connection_timeout"),
            7: ("CBErrorPeripheralDisconnected", "peripheral_disconnected"),
            8: ("CBErrorUUIDNotAllowed", "uuid_not_allowed"),
            9: ("CBErrorAlreadyAdvertising", "already_advertising"),
            10: ("CBErrorConnectionFailed", "connection_failed"),
            11: ("CBErrorConnectionLimitReached", "connection_limit_reached"),
            12: ("CBErrorUnknownDevice", "unknown_device"),
            13: ("CBErrorOperationNotSupported", "operation_not_supported"),
            14: ("CBErrorPeerRemovedPairingInformation", "peer_removed_pairing_information"),
            15: ("CBErrorEncryptionTimedOut", "encryption_timeout"),
            16: ("CBErrorTooManyLEPairedDevices", "too_many_le_paired_devices"),
            17: ("CBErrorLeGattExceededBackgroundNotificationLimit", "background_notification_limit_exceeded"),
            18: ("CBErrorLeGattNearBackgroundNotificationLimit", "background_notification_limit_near"),
        ],
        "android.bluetooth.BluetoothGatt": [
            2: ("GATT_READ_NOT_PERMITTED", "read_not_permitted"),
            3: ("GATT_WRITE_NOT_PERMITTED", "write_not_permitted"),
            5: ("GATT_INSUFFICIENT_AUTHENTICATION", "insufficient_authentication"),
            6: ("GATT_REQUEST_NOT_SUPPORTED", "request_not_supported"),
            7: ("GATT_INVALID_OFFSET", "invalid_offset"),
            8: ("GATT_INSUFFICIENT_AUTHORIZATION", "insufficient_authorization"),
            13: ("GATT_INVALID_ATTRIBUTE_LENGTH", "invalid_attribute_length"),
            15: ("GATT_INSUFFICIENT_ENCRYPTION", "insufficient_encryption"),
            143: ("GATT_CONNECTION_CONGESTED", "connection_congested"),
            147: ("GATT_CONNECTION_TIMEOUT", "connection_timeout"),
            257: ("GATT_FAILURE", "failure"),
        ],
    ]

    /// The platform error of a link that went down, as the radio reports it, with the code's
    /// platform name when it has one.
    static func platformError(_ domain: String, _ code: Int, _ message: String) -> BleObj {
        let e = obj(("domain", domain), ("code", code), ("message", message))
        if let n = errorNames[domain]?[code] { e["name"] = n.0 }
        return e
    }

    /// The link event's reason for an error: the code's readable reason, else the radio's.
    static func errorReason(_ e: BleObj?, _ fallback: String) -> String {
        guard let e = e, let d = e["domain"] as? String, let c = e["code"] as? Int,
              let n = errorNames[d]?[c] else { return fallback }
        return n.1
    }

    /// " (domain code name: message)" for a failed call's message, or "" without an error.
    static func errorText(_ e: BleObj?) -> String {
        guard let e = e else { return "" }
        func text(_ k: String) -> String { e[k].map { "\($0)" } ?? "" }
        let name = e["name"].map { " \($0)" } ?? ""
        return " (\(text("domain")) \(text("code"))\(name): \(text("message")))"
    }

    // MARK: replies and records

    private func ok(_ call: Int, _ data: BleObj) {
        if call >= 0 { port.reply(call, true, nil, nil, data) }
    }

    private func fail(_ call: Int, _ code: String, _ message: String) {
        if call >= 0 { port.reply(call, false, code, message, nil) }
    }

    /// "code message" from a port refusal, split.
    private func refused(_ call: Int, _ err: String) {
        if let sp = err.firstIndex(of: " ") {
            fail(call, String(err[..<sp]), String(err[err.index(after: sp)...]))
        } else {
            fail(call, err, "")
        }
    }

    private var journalCount: Int { journal.count - journalHead }

    private func append(_ event: String, _ data: BleObj) {
        nextSeq += 1
        let size = BleCore.json(data).utf8.count + 48
        journal.append((seq: nextSeq, t: port.now(), event: event, data: data, size: size))
        journalSize += size
        while journalCount > BleCore.journalRecords || journalSize > BleCore.journalBytes {
            journalSize -= journal[journalHead].size
            journalHead += 1
            dropped += 1
        }
        if journalHead > 4096 {
            journal.removeFirst(journalHead)
            journalHead = 0
        }
    }

    /// An event that is also a journal record.
    private func record(_ event: String, _ data: BleObj) {
        append(event, data)
        port.emit(event, data)
    }

    private func scheduleFlush() {
        if flushScheduled { return }
        flushScheduled = true
        port.timer("flush", 0, BleCore.flushMs)
    }

    private func flush() {
        flushScheduled = false
        if !pendingDevices.isEmpty {
            let batch = pendingDevices
            pendingDevices = []
            record("device", BleCore.obj(("scan", lastScan), ("devices", batch)))
        }
        if !pendingValues.isEmpty {
            let n = min(BleCore.batchMax, pendingValues.count)
            let batch: [Any] = Array(pendingValues[0..<n])
            pendingValues.removeFirst(n)
            port.emit("value", BleCore.obj(("records", batch), ("dropped", dropped)))
            if !pendingValues.isEmpty { scheduleFlush() }
        }
        if !pendingRequests.isEmpty {
            let n = min(BleCore.batchMax, pendingRequests.count)
            let batch: [Any] = Array(pendingRequests[0..<n])
            pendingRequests.removeFirst(n)
            port.emit("request", BleCore.obj(("records", batch), ("dropped", dropped)))
            if !pendingRequests.isEmpty { scheduleFlush() }
        }
    }

    // MARK: adapter

    var on: Bool { adapterState == "on" }

    private func orderedLinks() -> [Link] { linkOrder.compactMap { links[$0] } }

    private func putLink(_ l: Link) {
        if links[l.id] == nil { linkOrder.append(l.id) }
        links[l.id] = l
    }

    private func removeLink(_ id: String) {
        links[id] = nil
        linkOrder.removeAll { $0 == id }
    }

    private func putClosing(_ id: String, _ c: Closing) {
        if closing[id] == nil { closingOrder.append(id) }
        closing[id] = c
    }

    private func removeClosing(_ id: String) -> Closing? {
        let c = closing.removeValue(forKey: id)
        closingOrder.removeAll { $0 == id }
        return c
    }

    /// The adapter or manager state changed (on, off, unauthorized, unsupported, resetting, unknown).
    func adapter(_ state: String) {
        if state == adapterState { return }
        let wasOn = on
        adapterState = state
        if wasOn && !on {
            epoch += 1
            if scan != 0 { endScan("adapter") }
            serverDown()
            for l in orderedLinks() {
                if l.auto { setAutoWhenOn(l.id, l.wanted) }
                _ = closeLink(l, "adapter", down: true)
                // The radio is off: every platform object of the old epoch is released, none waited for.
                port.release(l.id, l.gen)
            }
            for id in closingOrder {
                let c = closing[id]!
                port.release(id, c.gen)
                if c.disconnectCall >= 0 {
                    ok(c.disconnectCall, BleCore.obj(("id", id), ("state", "disconnected"), ("confirmed", false)))
                }
                if let w = c.waiter { fail(w.call, "unavailable", "Bluetooth is \(state)") }
                if c.reconnect { setAutoWhenOn(id, c.wanted) }
            }
            closing = [:]
            closingOrder = []
        }
        record("adapter", BleCore.obj(("state", state), ("epoch", epoch)))
        if !wasOn && on {
            let again = autoWhenOn
            autoWhenOn = []
            for (id, wanted) in again {
                startLink(id, auto: true, call: -1, seconds: 0, background: true, wanted: wanted)
            }
            serverUp()
        }
        updateHold()
    }

    private func setAutoWhenOn(_ id: String, _ wanted: [String]) {
        if let i = autoWhenOn.firstIndex(where: { $0.0 == id }) { autoWhenOn[i].1 = wanted } else { autoWhenOn.append((id, wanted)) }
    }

    /// Fields of the state reply that the core owns.
    func stateFields() -> BleObj {
        BleCore.obj(("scanning", scan != 0), ("advertising", advertising), ("links", links.count),
                    ("centrals", centralList.count), ("keepAlive", keepAliveWanted), ("epoch", epoch), ("run", run))
    }

    // MARK: scan

    func scanStart(_ call: Int, _ servicesCsv: String?, _ seconds: Int, _ duplicates: Bool, _ mode: String, _ background: Bool) {
        guard let services = BleCore.uuidList(servicesCsv) else {
            fail(call, "bad_value", "services must be up to 20 UUIDs")
            return
        }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        if scan != 0 {
            fail(call, "busy", "a scan is already running")
            return
        }
        if background && services.isEmpty {
            fail(call, "filter_required", "a scan in the background needs a service filter")
            return
        }
        nextScan += 1
        let s = nextScan
        if let err = port.scanStart(s, services, duplicates, mode) {
            refused(call, err)
            return
        }
        scan = s
        lastScan = s
        devices = [:]
        deviceOrder = []
        filtered = !services.isEmpty
        if seconds > 0 { port.timer("scan", s, seconds * 1000) }
        ok(call, BleCore.obj(("scan", s)))
    }

    func scanStop(_ call: Int) {
        if scan == 0 {
            ok(call, BleCore.obj(("scan", lastScan), ("stopped", false)))
            return
        }
        let s = scan
        port.scanStop(s)
        endScan("stopped")
        ok(call, BleCore.obj(("scan", s), ("stopped", true)))
    }

    private func endScan(_ reason: String) {
        let s = scan
        scan = 0
        flush()
        record("scan_end", BleCore.obj(("scan", s), ("reason", reason)))
    }

    /// One advertisement. `adv` holds name, rssi, connectable, services, manufacturer, serviceData, txPower.
    func device(_ s: Int, _ id: String, _ adv: BleObj) {
        if s != scan || s == 0 {
            stale("device scan \(s)")
            return
        }
        var d = devices[id]
        if d == nil {
            if devices.count >= BleCore.devicesMax { return }
            let n = BleCore.obj(("id", id), ("seen", 0))
            devices[id] = n
            deviceOrder.append(id)
            d = n
        }
        d!.putAll(adv)
        d!["seen"] = (d!["seen"] as! Int) + 1
        let view = BleCore.obj(("id", id))
        view.putAll(adv)
        pendingDevices.append(view)
        scheduleFlush()
    }

    func scanFailed(_ s: Int, _ reason: String) {
        if s != scan || s == 0 {
            stale("scan_failed \(s)")
            return
        }
        endScan("failed")
    }

    /// The app moved to (true) or out of the background.
    func background(_ inBackground: Bool) {
        if inBackground && scan != 0 && !filtered {
            port.scanStop(scan)
            endScan("background")
        }
    }

    func devices(_ call: Int) {
        let out: [Any] = deviceOrder.compactMap { devices[$0] }
        ok(call, BleCore.obj(("devices", out)))
    }

    // MARK: links

    private func current(_ l: Link?, _ gen: Int) -> Bool {
        return l != nil && l!.gen == gen && !l!.closed
    }

    private func live(_ id: String, _ gen: Int, _ what: String) -> Link? {
        let l = links[id]
        if !current(l, gen) {
            stale("\(what) \(id) gen \(gen)")
            return nil
        }
        return l
    }

    private func stale(_ what: String) {
        staleDrops += 1
        port.stale(what)
    }

    private func checkId(_ call: Int, _ id: String?) -> Bool {
        if !BleCore.isId(id, android ? "android" : "ios") {
            fail(call, "bad_value", "id is not a device id of this platform")
            return false
        }
        return true
    }

    func connect(_ call: Int, _ id: String?, _ auto: Bool, _ seconds: Int) {
        guard checkId(call, id), let id = id else { return }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        if let l = links[id] {
            // A pending attempt no call owns (restored by iOS, or an automatic reconnect) is
            // adopted: this call owns it from now on, with its own timeout, and the page's `auto` wins.
            if l.state == "connecting" && l.connectCall < 0 && !l.closed {
                l.connectCall = call
                l.auto = auto
                l.background = false
                boundPending(l, seconds * 1000)
                return
            }
            fail(call, "busy", "this device is linked or connecting")
            return
        }
        if closing[id] != nil {
            // Rule 3: one live platform connection per device. Wait for the confirmed close.
            let c = closing[id]!
            if c.waiter != nil || c.reconnect {
                fail(call, "busy", "this device is still closing")
                return
            }
            nextOp += 1
            c.waiter = Waiter(call: call, auto: auto, seconds: seconds, token: nextOp)
            port.timer("wait", nextOp, seconds * 1000)
            return
        }
        startLink(id, auto: auto, call: call, seconds: seconds, background: false, wanted: [])
    }

    private func startLink(_ id: String, auto: Bool, call: Int, seconds: Int, background: Bool, wanted: [String]) {
        nextGen += 1
        let l = Link(id, nextGen)
        l.auto = auto
        l.background = background
        l.connectCall = call
        for k in wanted { l.addWanted(k) }
        putLink(l)
        if let err = port.connect(id, l.gen, auto, background) {
            removeLink(id)
            l.closed = true
            refused(call, err)
            return
        }
        if call >= 0 { port.timer("connect", l.gen, seconds * 1000) }
        if background {
            record("link", BleCore.obj(("id", id), ("link", l.gen), ("state", "reconnecting"), ("reason", "auto")))
        }
        updateHold()
    }

    /// Bounds an attempt no fresh connect started: when the timer ends it still connecting, the
    /// attempt is closed (the radio cancels it) and reported `timeout`.
    private func boundPending(_ l: Link, _ ms: Int) {
        nextPending += 1
        l.pendingTimer = nextPending
        port.timer("pending", nextPending, ms)
    }

    /// iOS state restoration: a peripheral the system kept for this app. Returns its gen. `pending`:
    /// iOS handed it back still connecting; the attempt is kept, bounded by the default connect
    /// timeout, and ends there unless a page `connect` adopts it (that call's timeout and `auto`).
    func restored(_ id: String, connected: Bool, subscribed: [String], pending: Bool = false) -> Int {
        nextGen += 1
        let l = Link(id, nextGen)
        l.auto = true
        l.background = true
        for k in subscribed {
            l.addWanted(k)
            l.setSub(k, "notify")
        }
        putLink(l)
        if connected {
            l.state = "connected"
        } else if pending {
            l.auto = false
            boundPending(l, BleCore.connectDefaultMs)
        }
        return l.gen
    }

    /// iOS state restoration finished: the `restored` event, kept in the journal like every event.
    func restoredEvent(_ data: BleObj) {
        record("restored", data)
    }

    func connected(_ id: String, _ gen: Int, _ mtu: Int) {
        guard let l = live(id, gen, "connected") else { return }
        if l.state != "connecting" { return }
        l.state = "connected"
        l.mtu = mtu
        if android {
            let m = Op(-1, "mtu")
            m.arg = BleCore.mtuRequest
            m.internal = true
            l.queue.append(m)
        }
        if !l.wanted.isEmpty {
            let d = Op(-1, "discover")
            d.internal = true
            l.queue.append(d)
            for k in l.wanted {
                let s = Op(-1, "sub")
                s.key = k
                s.internal = true
                l.queue.append(s)
            }
        }
        let ready = Op(-1, "ready")
        ready.internal = true
        l.queue.append(ready)
        pump(l)
    }

    /// The platform reported that attempt `gen` disconnected or failed to connect.
    /// `error`: the platform's own error, when it gave one ({domain, code, message}); it reaches the
    /// failed connect call's message and the `link` record unchanged.
    func disconnected(_ id: String, _ gen: Int, _ reason: String, error: BleObj? = nil) {
        let l = links[id]
        if current(l, gen) {
            _ = closeLink(l!, BleCore.errorReason(error, reason), down: true, error: error)
            return
        }
        if let c = closing[id], c.gen == gen {
            finishClosing(id, confirmed: true)
            return
        }
        stale("disconnected \(id) gen \(gen)")
    }

    func disconnect(_ call: Int, _ id: String?) {
        guard checkId(call, id), let id = id else { return }
        guard let l = links[id] else {
            fail(call, "not_connected", "this device is not linked")
            return
        }
        l.auto = false
        l.wanted = []
        let confirmedNow = closeLink(l, "requested", down: false)
        if confirmedNow {
            ok(call, BleCore.obj(("id", id), ("state", "disconnected"), ("confirmed", true)))
        } else {
            closing[id]!.disconnectCall = call
        }
    }

    /// The one cleanup owner (rule 4). Runs to the end, idempotent. `down`: the platform already
    /// reported the link down, so nothing is asked of it. Returns whether the close is confirmed now.
    @discardableResult
    func closeLink(_ l: Link, _ reason: String, down: Bool, error: BleObj? = nil) -> Bool {
        if l.closed { return true }
        l.closed = true
        var ops: [Op] = []
        if let f = l.inFlight { ops.append(f) }
        ops.append(contentsOf: l.queue)
        l.inFlight = nil
        l.queue = []
        for o in ops where !o.internal {
            let msg = o.chunks > 1 ? "the link closed after \(o.chunk) of \(o.chunks) chunks were handed over"
                : "the link closed while the operation waited"
            fail(o.call, "link_lost", msg)
        }
        if l.connectCall >= 0 {
            let code = reason == "timeout" ? "connect_timeout"
                : reason == "adapter" ? "unavailable"
                : reason == "requested" ? "link_lost" : "connect_failed"
            fail(l.connectCall, code, "the connection ended: \(reason)" + BleCore.errorText(error))
            l.connectCall = -1
        }
        if links[l.id] === l { removeLink(l.id) }
        var confirmed = down
        if !down {
            confirmed = port.close(l.id, l.gen)
            if !confirmed {
                putClosing(l.id, Closing(l.gen))
                port.timer("close", l.gen, BleCore.closeMs)
            }
        }
        let rec = BleCore.obj(("id", l.id), ("link", l.gen), ("state", "disconnected"), ("reason", reason))
        if let e = error { rec["error"] = e }
        record("link", rec)
        if l.auto && reason != "requested" && on {
            if let c = closing[l.id] {
                c.reconnect = true
                c.wanted = l.wanted
            } else {
                startLink(l.id, auto: true, call: -1, seconds: 0, background: true, wanted: l.wanted)
            }
        }
        updateHold()
        return confirmed
    }

    private func finishClosing(_ id: String, confirmed: Bool) {
        guard let c = removeClosing(id) else { return }
        if c.disconnectCall >= 0 {
            ok(c.disconnectCall, BleCore.obj(("id", id), ("state", "disconnected"), ("confirmed", confirmed)))
        }
        if !on {
            if let w = c.waiter { fail(w.call, "unavailable", "Bluetooth is \(adapterState)") }
            return
        }
        if c.reconnect {
            startLink(id, auto: true, call: -1, seconds: 0, background: true, wanted: c.wanted)
        } else if let w = c.waiter {
            if !port.isActive(w.call) {
                fail(w.call, "timeout", "the route timed out while the previous connection closed")
                return
            }
            startLink(id, auto: w.auto, call: w.call, seconds: w.seconds, background: false, wanted: [])
        }
    }

    func links(_ call: Int) {
        let out: [Any] = orderedLinks().map { l in
            BleCore.obj(("id", l.id), ("link", l.gen), ("state", l.state), ("auto", l.auto), ("mtu", l.mtu),
                        ("subscriptions", l.subs.map { $0.0 } as [Any]))
        }
        ok(call, BleCore.obj(("links", out)))
    }

    /// The link for `id` when it is current (for the radio's own lookups).
    func link(_ id: String) -> Link? { links[id] }

    // MARK: operations

    private func connectedLink(_ call: Int, _ id: String?) -> Link? {
        guard checkId(call, id), let id = id else { return nil }
        guard let l = links[id], l.state == "connected" else {
            fail(call, "not_connected", "this device is not connected")
            return nil
        }
        return l
    }

    private func target(_ call: Int, _ service: String?, _ sn: Int, _ chr: String?, _ cn: Int) -> String? {
        guard let s = BleCore.uuid(service), let c = BleCore.uuid(chr) else {
            fail(call, "bad_value", "service and char must be UUIDs")
            return nil
        }
        return BleCore.key(s, sn, c, cn)
    }

    private func enqueue(_ call: Int, _ l: Link, _ o: Op) {
        if l.queue.count >= BleCore.queueMax {
            fail(call, "busy", "too many operations are waiting on this link")
            return
        }
        l.queue.append(o)
        pump(l)
    }

    func discover(_ call: Int, _ id: String?) {
        if let l = connectedLink(call, id) { enqueue(call, l, Op(call, "discover")) }
    }

    func read(_ call: Int, _ id: String?, _ service: String?, _ sn: Int, _ chr: String?, _ cn: Int, _ descriptor: String?) {
        guard let l = connectedLink(call, id) else { return }
        guard let k = target(call, service, sn, chr, cn) else { return }
        var d: String?
        if descriptor != nil {
            d = BleCore.uuid(descriptor)
            if d == nil {
                fail(call, "bad_value", "descriptor must be a UUID")
                return
            }
        }
        let o = Op(call, "read")
        o.key = k
        o.descriptor = d
        enqueue(call, l, o)
    }

    func write(_ call: Int, _ id: String?, _ service: String?, _ sn: Int, _ chr: String?, _ cn: Int, _ descriptor: String?,
               _ hexValue: String?, _ b64Value: String?, _ response: Bool) {
        guard let l = connectedLink(call, id) else { return }
        guard let k = target(call, service, sn, chr, cn) else { return }
        guard let data = BleCore.bytes(hexValue, b64Value) else {
            fail(call, "bad_value", "give exactly one of hex and b64, well formed")
            return
        }
        if data.count > BleCore.writeMax {
            fail(call, "too_long", "\(data.count) bytes; at most \(BleCore.writeMax)")
            return
        }
        var withResponse = response
        var d: String?
        if descriptor != nil {
            d = BleCore.uuid(descriptor)
            if d == nil {
                fail(call, "bad_value", "descriptor must be a UUID")
                return
            }
            withResponse = true
        }
        let o = Op(call, withResponse ? "write" : "wnr")
        o.key = k
        o.descriptor = d
        o.data = data
        enqueue(call, l, o)
    }

    func subscribe(_ call: Int, _ id: String?, _ service: String?, _ sn: Int, _ chr: String?, _ cn: Int, _ on: Bool) {
        guard let l = connectedLink(call, id) else { return }
        guard let k = target(call, service, sn, chr, cn) else { return }
        let o = Op(call, on ? "sub" : "unsub")
        o.key = k
        enqueue(call, l, o)
    }

    func rssi(_ call: Int, _ id: String?) {
        if let l = connectedLink(call, id) { enqueue(call, l, Op(call, "rssi")) }
    }

    func mtu(_ call: Int, _ id: String?, _ size: Int) {
        guard let l = connectedLink(call, id) else { return }
        if !android {
            ok(call, BleCore.mtuData(l, requested: false))
            return
        }
        let o = Op(call, "mtu")
        o.arg = size
        enqueue(call, l, o)
    }

    private static func mtuData(_ l: Link, requested: Bool) -> BleObj {
        obj(("mtu", l.mtu), ("writeMax", writeMax), ("writeNoResponseMax", l.mtu - 3), ("requested", requested))
    }

    /// Hands the next operation to the platform when none is in flight.
    private func pump(_ l: Link) {
        while l.inFlight == nil && !l.queue.isEmpty && !l.closed {
            let o = l.queue.removeFirst()
            if !o.internal && !port.isActive(o.call) {
                // Rule 8: a route that timed out starts nothing new. Its reply is the bridge's to drop.
                fail(o.call, "timeout", "the route timed out before the operation started")
                continue
            }
            if o.kind == "ready" {
                ready(l)
                continue
            }
            if o.kind == "wnr" {
                let size = max(1, l.mtu - 3)
                o.chunks = max(1, (o.data!.count + size - 1) / size)
                o.chunk = 0
            }
            l.inFlight = o
            send(l, o)
        }
    }

    private func send(_ l: Link, _ o: Op) {
        nextOp += 1
        o.op = nextOp
        var data = o.data
        if o.kind == "wnr", let all = o.data {
            let size = max(1, l.mtu - 3)
            let from = o.chunk * size, to = min(all.count, from + size)
            data = Array(all[from..<to])
        }
        if let err = port.op(l.id, l.gen, o.op, o.kind, o.key, o.descriptor, data, o.arg) {
            // Rule 6: a refusal settles the step at once and the queue moves on.
            l.inFlight = nil
            if o.internal {
                if o.kind == "sub" { l.failed += 1 }
            } else {
                refused(o.call, err)
            }
            pump(l)
            return
        }
        port.timer("op", o.op, BleCore.opMs)
    }

    private func ready(_ l: Link) {
        record("link", BleCore.obj(("id", l.id), ("link", l.gen), ("state", "connected"),
                                   ("reason", l.background ? "auto" : "requested"),
                                   ("resubscribed", l.resubscribed), ("failed", l.failed)))
        if l.connectCall >= 0 {
            ok(l.connectCall, BleCore.obj(("id", l.id), ("link", l.gen), ("state", "connected"), ("mtu", l.mtu)))
            l.connectCall = -1
        }
    }

    /// One GATT step settled. `code` nil is success; `data` carries the platform's answer
    /// (discover: services; read: hex; rssi: rssi; sub: mode).
    func opDone(_ id: String, _ gen: Int, _ op: Int, _ code: String?, _ message: String?, _ data: BleObj?) {
        guard let l = live(id, gen, "op") else { return }
        guard let o = l.inFlight, o.op == op else {
            stale("op \(op)")
            return
        }
        if code == nil && o.kind == "wnr" && o.chunk + 1 < o.chunks {
            o.chunk += 1
            send(l, o)
            return
        }
        l.inFlight = nil
        settle(l, o, code, message, data)
        pump(l)
    }

    private func settle(_ l: Link, _ o: Op, _ code: String?, _ message: String?, _ data: BleObj?) {
        if o.internal {
            if o.kind == "sub" {
                if code == nil {
                    l.setSub(o.key!, (data?["mode"] as? String) ?? "notify")
                    l.resubscribed += 1
                } else {
                    l.failed += 1
                }
            }
            return
        }
        if let code = code {
            fail(o.call, code, message ?? "")
            return
        }
        switch o.kind {
        case "write":
            ok(o.call, BleCore.obj(("written", o.data!.count), ("chunks", 1)))
        case "wnr":
            ok(o.call, BleCore.obj(("written", o.data!.count), ("chunks", o.chunks)))
        case "sub":
            let mode = (data?["mode"] as? String) ?? "notify"
            l.setSub(o.key!, mode)
            l.addWanted(o.key!)
            ok(o.call, BleCore.obj(("subscribed", true), ("mode", mode)))
        case "unsub":
            l.subs.removeAll { $0.0 == o.key! }
            l.wanted.removeAll { $0 == o.key! }
            ok(o.call, BleCore.obj(("subscribed", false)))
        case "mtu":
            ok(o.call, BleCore.mtuData(l, requested: true))
        case "discover":
            let out = BleCore.obj(("id", l.id))
            if let d = data { out.putAll(d) }
            ok(o.call, out)
        default:
            ok(o.call, data ?? BleObj())
        }
    }

    /// The link's MTU changed. It completes the operation in flight only if that is the MTU request.
    func mtuChanged(_ id: String, _ gen: Int, _ mtu: Int, _ success: Bool) {
        guard let l = live(id, gen, "mtu") else { return }
        if success { l.mtu = mtu }
        if let o = l.inFlight, o.kind == "mtu" {
            l.inFlight = nil
            settle(l, o, nil, nil, nil)
            pump(l)
        }
    }

    /// A characteristic value arrived. `maybeRead`: the platform cannot say whether it answers a
    /// read (iOS didUpdateValueFor); then a read of this characteristic in flight takes it.
    func value(_ id: String, _ gen: Int, _ key: String, _ hexValue: String, _ maybeRead: Bool) {
        guard let l = live(id, gen, "value") else { return }
        if maybeRead, let o = l.inFlight, o.kind == "read", o.descriptor == nil, o.key == key {
            l.inFlight = nil
            settle(l, o, nil, nil, BleCore.obj(("hex", hexValue)))
            pump(l)
            return
        }
        let parts = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
        let rec = BleCore.obj(("id", id), ("link", gen), ("service", parts[0]), ("char", parts[2]),
                              ("service_n", Int(parts[1])!), ("char_n", Int(parts[3])!), ("hex", hexValue))
        append("value", rec)
        let view = BleCore.obj(("seq", nextSeq), ("t", journal[journal.count - 1].t))
        view.putAll(rec)
        pendingValues.append(view)
        scheduleFlush()
    }

    /// The remote GATT table changed: cached handles are gone, the next operation needs discover.
    func gattChanged(_ id: String, _ gen: Int) {
        guard live(id, gen, "gatt_changed") != nil else { return }
        record("gatt_changed", BleCore.obj(("id", id), ("link", gen)))
    }

    // MARK: peripheral role: GATT server, advertising, keep-alive

    static let charsMax = 16
    static let servicesMax = 32
    static let notifyMax = 128
    static let persistMs = 500

    final class Chr {
        let uuid: String
        let n: Int
        let flags: String
        var value: [UInt8]?
        /// Subscribed centrals and their mode (notify or indicate), in subscription order.
        var subscribers: [(String, String)] = []

        init(_ uuid: String, _ n: Int, _ flags: String, _ value: [UInt8]?) {
            self.uuid = uuid
            self.n = n
            self.flags = flags
            self.value = value
        }

        func has(_ f: Character) -> Bool { flags.contains(f) }

        func mode(_ central: String) -> String? { subscribers.first { $0.0 == central }?.1 }

        func setMode(_ central: String, _ mode: String) {
            if let i = subscribers.firstIndex(where: { $0.0 == central }) {
                subscribers[i].1 = mode
            } else {
                subscribers.append((central, mode))
            }
        }

        func remove(_ central: String) { subscribers.removeAll { $0.0 == central } }
    }

    final class Service {
        let uuid: String
        let primary: Bool
        let chars: [Chr]
        var added = false
        /// Restored by iOS without a readable ble-server.json: its values are gone.
        var lost = false
        var call = -1
        var token = 0

        init(_ uuid: String, _ primary: Bool, _ chars: [Chr]) {
            self.uuid = uuid
            self.primary = primary
            self.chars = chars
        }
    }

    final class Job {
        let call: Int
        let total: Int
        var left: Int
        var sent = 0
        var started = false, failed = false

        init(_ call: Int, _ total: Int) {
            self.call = call
            self.total = total
            self.left = total
        }
    }

    final class Packet {
        let job: Job
        let central: String, key: String
        let data: [UInt8]
        let indicate: Bool
        var packet = 0

        init(_ job: Job, _ central: String, _ key: String, _ data: [UInt8], _ indicate: Bool) {
            self.job = job
            self.central = central
            self.key = key
            self.data = data
            self.indicate = indicate
        }
    }

    private var services: [Service] = []
    private var addQueue: [Service] = []
    private var adding: Service?
    /// Remote centrals by id, with their MTU, in arrival order.
    private var centralList: [(String, Int)] = []
    /// Android prepared writes, by central and key, committed on execute.
    private var prepared: [(String, [UInt8])] = []
    private var notifyQueue: [Packet] = []
    private var sending: Packet?
    private var waitingReady = false
    private var pendingRequests: [BleObj] = []
    /// The page's standing advertising request (cleared by advertise_stop, elapsed or a failed start).
    private var advWanted: BleObj?
    private var advUntil = 0
    private var adv = 0, nextAdv = 0
    /// iOS: the advertisement token the server restoration made (the radio stops it by this token).
    var advertisingToken: Int { adv }
    private(set) var advertising = false
    private var advCall = -1
    private var keepAliveWanted = false, holdActive = false
    private var holdGen = 0
    private var holdReason: String?
    private var persistScheduled = false

    private func service(_ uuid: String) -> Service? { services.first { $0.uuid == uuid } }

    private func centralMtu(of central: String) -> Int? { centralList.first { $0.0 == central }?.1 }

    private func setCentral(_ central: String, _ mtu: Int) {
        if let i = centralList.firstIndex(where: { $0.0 == central }) { centralList[i].1 = mtu } else { centralList.append((central, mtu)) }
    }

    /// The `chars` grammar of service_add (BleCore.java parseChars): `uuid~flags` or
    /// `uuid~flags~hex`, comma-separated, at most 16; equal UUIDs are numbered in order. nil when malformed.
    static func parseChars(_ spec: String?) -> [BleObj]? {
        var out: [BleObj] = []
        guard let spec = spec, !spec.isEmpty else { return out }
        var seen: [String: Int] = [:]
        for part in spec.split(separator: ",", omittingEmptySubsequences: false) {
            let f = part.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            if f.count < 2 || f.count > 3 { return nil }
            let flags = f[1]
            guard let u = uuid(f[0].trimmingCharacters(in: .whitespaces)), !flags.isEmpty else { return nil }
            var letters = Set<Character>()
            for c in flags {
                if !"rwcniRW".contains(c) || letters.contains(c) { return nil }
                letters.insert(c)
            }
            if !flags.contains(where: { "rwcni".contains($0) }) { return nil }
            if flags.contains("R") && !flags.contains("r") { return nil }
            if flags.contains("W") && !flags.contains("w") && !flags.contains("c") { return nil }
            var start: Any = NSNull()
            if f.count == 3 {
                guard let b = fromHex(f[2]), !f[2].isEmpty, b.count <= writeMax else { return nil }
                start = hex(b)
            }
            let n = seen[u].map { $0 + 1 } ?? 0
            seen[u] = n
            out.append(obj(("uuid", u), ("n", n), ("flags", flags), ("hex", start)))
            if out.count > charsMax { return nil }
        }
        return out
    }

    /// Server and advertiser callbacks carry the epoch they were made in; an older one changes nothing.
    private func serverCurrent(_ e: Int, _ what: String) -> Bool {
        if e == epoch && on { return true }
        stale("\(what) epoch \(e)")
        return false
    }

    private func chr(_ serviceUUID: String?, _ chrUUID: String?, _ cn: Int) -> Chr? {
        guard let s = BleCore.uuid(serviceUUID), let c = BleCore.uuid(chrUUID), let svc = service(s) else { return nil }
        return svc.chars.first { $0.uuid == c && $0.n == cn }
    }

    private func chrOf(_ key: String) -> Chr? {
        let p = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
        guard p.count == 4, let svc = service(p[0]), let cn = Int(p[3]) else { return nil }
        return svc.chars.first { $0.uuid == p[2] && $0.n == cn }
    }

    private func lostService(_ key: String) -> Bool {
        service(String(key.prefix(while: { $0 != "#" })))?.lost ?? false
    }

    private static func keyOf(_ s: Service, _ c: Chr) -> String { key(s.uuid, 0, c.uuid, c.n) }

    private static func properties(_ c: Chr) -> [Any] {
        var out: [Any] = []
        if c.has("r") { out.append("read") }
        if c.has("c") { out.append("writeWithoutResponse") }
        if c.has("w") { out.append("write") }
        if c.has("n") { out.append("notify") }
        if c.has("i") { out.append("indicate") }
        return out
    }

    private static func charList(_ s: Service) -> [BleObj] {
        s.chars.map { c in
            obj(("uuid", c.uuid), ("n", c.n), ("flags", c.flags), ("hex", c.value.map { hex($0) as Any } ?? NSNull()))
        }
    }

    private func serviceView(_ s: Service) -> BleObj {
        let chars: [Any] = s.chars.map { c in
            BleCore.obj(("uuid", c.uuid), ("n", c.n), ("properties", BleCore.properties(c)),
                        ("subscribers", c.subscribers.map { $0.0 } as [Any]),
                        ("hex", c.value.map { BleCore.hex($0) as Any } ?? NSNull()))
        }
        return BleCore.obj(("uuid", s.uuid), ("primary", s.primary), ("added", s.added), ("characteristics", chars))
    }

    func serviceAdd(_ call: Int, _ uuidValue: String?, _ primary: Bool, _ spec: String?) {
        let u = BleCore.uuid(uuidValue)
        let parsed = BleCore.parseChars(spec)
        guard let uu = u, let list = parsed else {
            fail(call, "bad_value", u == nil ? "uuid must be a UUID" : "chars does not follow uuid~flags[~hex], at most 16")
            return
        }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        if service(uu) != nil {
            fail(call, "bad_value", "this service is already in the table")
            return
        }
        if services.count >= BleCore.servicesMax {
            fail(call, "busy", "the table holds \(BleCore.servicesMax) services")
            return
        }
        let chars = list.map { c -> Chr in
            Chr(c["uuid"] as! String, c["n"] as! Int, c["flags"] as! String,
                (c["hex"] as? String).flatMap { BleCore.fromHex($0) } ?? [])
        }
        let s = Service(uu, primary, chars)
        s.call = call
        services.append(s)
        addQueue.append(s)
        pumpAdds()
    }

    /// Hands the next service to the platform; one add in flight, as Android requires.
    private func pumpAdds() {
        while adding == nil && !addQueue.isEmpty {
            let s = addQueue.removeFirst()
            if s.call >= 0 && !port.isActive(s.call) {
                services.removeAll { $0 === s }
                fail(s.call, "timeout", "the route timed out before the service was added")
                continue
            }
            if let err = port.serviceAdd(epoch, s.uuid, s.primary, BleCore.charList(s)) {
                if s.call >= 0 {
                    services.removeAll { $0 === s }
                    refused(s.call, err)
                    s.call = -1
                }
                continue
            }
            adding = s
            nextOp += 1
            s.token = nextOp
            port.timer("service", s.token, BleCore.opMs)
        }
    }

    /// The platform added (code nil) or refused a service.
    func serviceAdded(_ e: Int, _ uuidValue: String, _ code: String?) {
        if !serverCurrent(e, "service_added") { return }
        guard let s = adding, s.uuid == uuidValue else {
            stale("service_added \(uuidValue)")
            return
        }
        adding = nil
        if code == nil {
            s.added = true
            if s.call >= 0 { ok(s.call, BleCore.obj(("uuid", s.uuid), ("characteristics", serviceView(s)["characteristics"]!))) }
            persistSoon()
        } else if s.call >= 0 {
            services.removeAll { $0 === s }
            fail(s.call, "gatt_error", "the platform refused the service: \(code!)")
        }
        s.call = -1
        pumpAdds()
    }

    func serviceRemove(_ call: Int, _ uuidValue: String?) {
        var targets: [Service] = []
        if let raw = uuidValue {
            guard let u = BleCore.uuid(raw) else {
                fail(call, "bad_value", "uuid must be a UUID")
                return
            }
            guard let s = service(u) else {
                fail(call, "not_found", "no such service in the table")
                return
            }
            targets.append(s)
        } else {
            targets = services
        }
        for s in targets where s === adding || s.call >= 0 {
            fail(call, "busy", "a service is still being added")
            return
        }
        var removed: [Any] = []
        for s in targets {
            services.removeAll { $0 === s }
            addQueue.removeAll { $0 === s }
            if s.added { port.serviceRemove(s.uuid) }
            for c in s.chars {
                for (central, _) in c.subscribers { dropSubscription(central, s.uuid, c) }
            }
            removed.append(s.uuid)
        }
        persistSoon()
        ok(call, BleCore.obj(("removed", removed)))
        pumpNotify()
    }

    func servicesList(_ call: Int) {
        ok(call, BleCore.obj(("services", services.map { serviceView($0) } as [Any]), ("advertising", advertising)))
    }

    func valueSet(_ call: Int, _ serviceUUID: String?, _ chrUUID: String?, _ cn: Int, _ hexValue: String?, _ b64Value: String?) {
        guard let c = chr(serviceUUID, chrUUID, cn) else {
            fail(call, "not_found", "no such characteristic in the table")
            return
        }
        guard let data = BleCore.bytes(hexValue, b64Value) else {
            fail(call, "bad_value", "give exactly one of hex and b64, well formed")
            return
        }
        if overMax(call, data) { return }
        c.value = data
        persistSoon()
        ok(call, BleCore.obj(("bytes", data.count)))
    }

    /// A server value is at most 512 bytes, as an attribute value is.
    private func overMax(_ call: Int, _ data: [UInt8]) -> Bool {
        if data.count <= BleCore.writeMax { return false }
        fail(call, "too_long", "\(data.count) bytes; at most \(BleCore.writeMax)")
        return true
    }

    func notify(_ call: Int, _ serviceUUID: String?, _ chrUUID: String?, _ cn: Int, _ hexValue: String?, _ b64Value: String?,
                _ central: String?) {
        guard let c = chr(serviceUUID, chrUUID, cn) else {
            fail(call, "not_found", "no such characteristic in the table")
            return
        }
        guard let data = BleCore.bytes(hexValue, b64Value) else {
            fail(call, "bad_value", "give exactly one of hex and b64, well formed")
            return
        }
        if overMax(call, data) { return }
        if !c.has("n") && !c.has("i") {
            fail(call, "not_permitted", "the characteristic neither notifies nor indicates")
            return
        }
        let to = c.subscribers.map { $0.0 }.filter { central == nil || central == $0 }
        if to.isEmpty {
            fail(call, "no_subscribers", central == nil ? "no central is subscribed" : "that central is not subscribed")
            return
        }
        var room = Int.max
        for x in to { room = min(room, (centralMtu(of: x) ?? 23) - 3) }
        if data.count > room {
            fail(call, "too_long", "\(data.count) bytes; a subscriber's MTU allows \(room)")
            return
        }
        if notifyQueue.count + to.count > BleCore.notifyMax {
            fail(call, "busy", "too many notifications are waiting")
            return
        }
        c.value = data
        persistSoon()
        var key = ""
        for s in services where s.chars.contains(where: { $0 === c }) { key = BleCore.keyOf(s, c) }
        let job = Job(call, to.count)
        for x in to { notifyQueue.append(Packet(job, x, key, data, c.mode(x) == "indicate")) }
        pumpNotify()
    }

    private func resolve(_ p: Packet, _ sent: Bool) {
        let j = p.job
        j.left -= 1
        if sent { j.sent += 1 }
        if j.left == 0 && !j.failed { ok(j.call, BleCore.obj(("sent", j.sent), ("subscribers", j.total))) }
    }

    private func failJob(_ j: Job, _ code: String, _ message: String) {
        if j.failed { return }
        j.failed = true
        fail(j.call, code, message)
    }

    /// Sends queued packets one at a time, in order.
    private func pumpNotify() {
        while sending == nil && !waitingReady && !notifyQueue.isEmpty {
            let p = notifyQueue[0]
            if !p.job.failed && !p.job.started && !port.isActive(p.job.call) {
                failJob(p.job, "timeout", "the route timed out before the notification was sent")
            }
            let c = p.job.failed ? nil : chrOf(p.key)
            if c == nil || c!.mode(p.central) == nil {
                notifyQueue.removeFirst()
                resolve(p, false)
                continue
            }
            p.job.started = true
            nextOp += 1
            p.packet = nextOp
            let r = port.notify(epoch, p.packet, p.central, p.key, p.data, p.indicate)
            if r == "full" {
                waitingReady = true
                return
            }
            notifyQueue.removeFirst()
            if r == nil {
                resolve(p, true)
            } else if r == "pending" {
                sending = p
                port.timer("notify", p.packet, BleCore.opMs)
            } else {
                let err = r!
                if let sp = err.firstIndex(of: " ") {
                    failJob(p.job, String(err[..<sp]), String(err[err.index(after: sp)...]))
                } else {
                    failJob(p.job, err, "")
                }
                resolve(p, false)
            }
        }
    }

    /// Android onNotificationSent for packet `packet`.
    func notifySent(_ e: Int, _ packet: Int, _ code: String?) {
        if !serverCurrent(e, "notify_sent") { return }
        guard let p = sending, p.packet == packet else {
            stale("notify_sent \(packet)")
            return
        }
        sending = nil
        if let code = code { failJob(p.job, "gatt_error", "the notification failed: \(code)") }
        resolve(p, code == nil)
        pumpNotify()
    }

    /// iOS peripheralManagerIsReady(toUpdateSubscribers:): the transmit queue has room again.
    func notifyReady(_ e: Int) {
        if !serverCurrent(e, "notify_ready") { return }
        if !waitingReady { return }
        waitingReady = false
        pumpNotify()
    }

    /// A remote central connected to this server (Android), or was first seen (iOS).
    func centralConnected(_ e: Int, _ central: String, _ mtu: Int) {
        if !serverCurrent(e, "central") { return }
        seen(central, mtu)
    }

    private func seen(_ central: String, _ mtu: Int) {
        if centralMtu(of: central) != nil {
            if mtu > 0 { setCentral(central, mtu) }
            return
        }
        setCentral(central, mtu > 0 ? mtu : 23)
        record("central", BleCore.obj(("central", central), ("state", "connected"), ("mtu", centralMtu(of: central)!)))
        updateHold()
    }

    func centralMtu(_ e: Int, _ central: String, _ mtu: Int) {
        if !serverCurrent(e, "central_mtu") { return }
        if centralMtu(of: central) != nil { setCentral(central, mtu) }
    }

    func centralDisconnected(_ e: Int, _ central: String) {
        if !serverCurrent(e, "central_gone") { return }
        if centralMtu(of: central) == nil {
            stale("central_gone " + central)
            return
        }
        endCentral(central, "remote")
        pumpNotify()
    }

    private func endCentral(_ central: String, _ reason: String) {
        for s in services { for c in s.chars { c.remove(central) } }
        prepared.removeAll { $0.0.hasPrefix(central + "|") }
        centralList.removeAll { $0.0 == central }
        record("central", BleCore.obj(("central", central), ("state", "disconnected"), ("reason", reason)))
        updateHold()
    }

    private func dropSubscription(_ central: String, _ serviceUUID: String, _ c: Chr) {
        c.remove(central)
        record("central", BleCore.obj(("central", central), ("state", "unsubscribed"), ("service", serviceUUID),
                                      ("char", c.uuid), ("char_n", c.n)))
        if !android && !subscribed(central) { centralList.removeAll { $0.0 == central } }
    }

    private func subscribed(_ central: String) -> Bool {
        services.contains { s in s.chars.contains { $0.mode(central) != nil } }
    }

    /// A central subscribed (`mode` notify or indicate) or unsubscribed (nil). Returns the ATT
    /// outcome: ok, not_found, not_permitted or stale.
    func subscription(_ e: Int, _ central: String, _ mtu: Int, _ key: String, _ mode: String?) -> String {
        if !serverCurrent(e, "subscription") { return "stale" }
        guard let c = chrOf(key) else { return "not_found" }
        if let m = mode, !c.has(m == "indicate" ? "i" : "n") { return "not_permitted" }
        seen(central, mtu)
        let svc = String(key.prefix(while: { $0 != "#" }))
        if let m = mode {
            c.setMode(central, m)
            record("central", BleCore.obj(("central", central), ("state", "subscribed"), ("service", svc), ("char", c.uuid),
                                          ("char_n", c.n), ("mode", m), ("mtu", centralMtu(of: central)!)))
        } else if c.mode(central) != nil {
            dropSubscription(central, svc, c)
        }
        pumpNotify()
        return "ok"
    }

    /// Android: the CCCD value this central reads back.
    func cccd(_ central: String, _ key: String) -> String {
        switch chrOf(key)?.mode(central) {
        case nil: return "0000"
        case "indicate"?: return "0200"
        default: return "0100"
        }
    }

    /// A read request, answered from the value store: {status, hex}. Status ok, not_found,
    /// not_permitted, invalid_offset, unlikely or stale.
    func readRequest(_ e: Int, _ central: String, _ mtu: Int, _ key: String, _ offset: Int) -> BleObj {
        if !serverCurrent(e, "read_request") { return BleCore.obj(("status", "stale")) }
        guard let c = chrOf(key) else { return BleCore.obj(("status", lostService(key) ? "unlikely" : "not_found")) }
        seen(central, mtu)
        if !c.has("r") { return BleCore.obj(("status", "not_permitted")) }
        guard let v = c.value else { return BleCore.obj(("status", "unlikely")) }
        if offset > v.count { return BleCore.obj(("status", "invalid_offset")) }
        return BleCore.obj(("status", "ok"), ("hex", BleCore.hex(Array(v[offset...]))))
    }

    /// Write requests of one central, applied all or none (iOS delivers a batch and answers it once;
    /// Android passes one). Each is {key, offset, hex}. `prepare`: an Android prepared write.
    func writeRequests(_ e: Int, _ central: String, _ mtu: Int, _ reqs: [BleObj], _ prepare: Bool) -> String {
        if !serverCurrent(e, "write_request") { return "stale" }
        var next: [(String, [UInt8])] = []
        for r in reqs {
            let key = r["key"] as! String
            guard let c = chrOf(key) else { return "not_found" }
            if !c.has("w") && !c.has("c") { return "not_permitted" }
            guard let data = BleCore.fromHex(r["hex"] as? String) else { return "invalid_length" }
            let slot = prepare ? central + "|" + key : key
            let base = next.last { $0.0 == slot }?.1
                ?? (prepare ? prepared.first { $0.0 == slot }?.1 ?? [] : c.value ?? [])
            let offset = r["offset"] as! Int
            if offset > base.count { return "invalid_offset" }
            if offset + data.count > BleCore.writeMax { return "invalid_length" }
            let v = Array(base[0..<offset]) + data
            if let i = next.firstIndex(where: { $0.0 == slot }) { next[i].1 = v } else { next.append((slot, v)) }
        }
        seen(central, mtu)
        for (slot, v) in next {
            if prepare {
                if let i = prepared.firstIndex(where: { $0.0 == slot }) { prepared[i].1 = v } else { prepared.append((slot, v)) }
            } else {
                commit(central, slot, v)
            }
        }
        return "ok"
    }

    /// Android onExecuteWrite: commit (true) or drop this central's prepared writes.
    func executeWrite(_ e: Int, _ central: String, _ execute: Bool) -> String {
        if !serverCurrent(e, "execute_write") { return "stale" }
        let mine = prepared.filter { $0.0.hasPrefix(central + "|") }
        prepared.removeAll { $0.0.hasPrefix(central + "|") }
        if execute {
            for (slot, v) in mine { commit(central, String(slot.dropFirst(central.count + 1)), v) }
        }
        return "ok"
    }

    private func commit(_ central: String, _ key: String, _ v: [UInt8]) {
        guard let c = chrOf(key) else { return }
        c.value = v
        let p = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
        let rec = BleCore.obj(("central", central), ("kind", "write"), ("service", p[0]), ("char", p[2]),
                              ("char_n", Int(p[3])!), ("hex", BleCore.hex(v)))
        append("request", rec)
        let view = BleCore.obj(("seq", nextSeq), ("t", journal[journal.count - 1].t))
        view.putAll(rec)
        pendingRequests.append(view)
        scheduleFlush()
        persistSoon()
    }

    func centrals(_ call: Int) {
        let out: [Any] = centralList.map { (central, mtu) in
            var subs: [Any] = []
            for s in services { for c in s.chars where c.mode(central) != nil { subs.append(BleCore.keyOf(s, c)) } }
            return BleCore.obj(("central", central), ("mtu", mtu), ("subscriptions", subs))
        }
        ok(call, BleCore.obj(("centrals", out)))
    }

    func centralDrop(_ call: Int, _ central: String?) {
        if !android {
            fail(call, "platform_limit", "iOS has no API to drop a remote central")
            return
        }
        guard let c = central, BleCore.isId(c, "android"), centralMtu(of: c) != nil else {
            fail(call, "unknown_device", "that central is not connected")
            return
        }
        port.centralDrop(c)
        ok(call, BleCore.obj(("dropped", true)))
    }

    // MARK: advertising

    func advertiseStart(_ call: Int, _ servicesCsv: String?, _ name: String?, _ manufacturerId: Int, _ manufacturerHex: String?,
                        _ serviceDataUuid: String?, _ serviceDataHex: String?, _ connectable: Bool, _ mode: String, _ seconds: Int) {
        guard let uuids = BleCore.uuidList(servicesCsv) else {
            fail(call, "bad_value", "services must be up to 20 UUIDs")
            return
        }
        if (manufacturerId < 0) != (manufacturerHex == nil) || manufacturerId > 0xFFFF
            || (manufacturerHex != nil && BleCore.fromHex(manufacturerHex) == nil) {
            fail(call, "bad_value", "manufacturer_id (0 to 65535) and manufacturer_hex go together, as an id and hex bytes")
            return
        }
        let sdUuid = serviceDataUuid.flatMap { BleCore.uuid($0) }
        if (serviceDataUuid == nil) != (serviceDataHex == nil) || (serviceDataUuid != nil && sdUuid == nil)
            || (serviceDataHex != nil && BleCore.fromHex(serviceDataHex) == nil) {
            fail(call, "bad_value", "service_data_uuid and service_data_hex go together, as a UUID and hex bytes")
            return
        }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        if adv != 0 {
            fail(call, "busy", "advertising is already running")
            return
        }
        let p = BleCore.obj(("services", uuids as [Any]), ("name", BleCore.nul(name)),
                            ("manufacturerId", BleCore.nul(manufacturerId < 0 ? nil : manufacturerId)),
                            ("manufacturerHex", BleCore.nul(manufacturerHex?.lowercased())),
                            ("serviceDataUuid", BleCore.nul(sdUuid)),
                            ("serviceDataHex", BleCore.nul(serviceDataHex?.lowercased())),
                            ("connectable", connectable), ("mode", mode), ("seconds", seconds))
        advWanted = p
        advUntil = 0
        advCall = call
        startAdvertising(seconds)
    }

    private func startAdvertising(_ seconds: Int) {
        nextAdv += 1
        let t = nextAdv
        let p = advWanted!
        p["seconds"] = seconds
        if let err = port.advertiseStart(epoch, t, p) {
            advWanted = nil
            if advCall >= 0 { refused(advCall, err) } else { record("advertise_end", BleCore.obj(("reason", "failed"))) }
            advCall = -1
            return
        }
        adv = t
        port.timer("advertise_start", t, BleCore.opMs)
    }

    private static func isSet(_ v: Any?) -> Bool { v != nil && !(v is NSNull) }

    /// A JSON value, null when absent (BleObj keeps no nil).
    private static func nul(_ v: Any?) -> Any { v ?? NSNull() }

    /// What this platform really advertises of the request.
    private func applied(_ p: BleObj) -> BleObj {
        BleCore.obj(("name", BleCore.nul(BleCore.isSet(p["name"]) ? (android ? "adapter" : "given") : nil)),
                    ("manufacturer", android && BleCore.isSet(p["manufacturerId"])),
                    ("serviceData", android && BleCore.isSet(p["serviceDataUuid"])),
                    ("connectable", android ? p["connectable"]! : true as Any),
                    ("mode", android ? p["mode"]! : NSNull() as Any))
    }

    func advertiseStarted(_ e: Int, _ t: Int, _ code: String?) {
        if !serverCurrent(e, "advertise_started") { return }
        if t != adv || advertising {
            stale("advertise_started \(t)")
            return
        }
        if let code = code {
            adv = 0
            advWanted = nil
            if advCall >= 0 { fail(advCall, "advertise_failed", code) } else { record("advertise_end", BleCore.obj(("reason", "failed"))) }
            advCall = -1
            return
        }
        if advCall >= 0 && !port.isActive(advCall) {
            // The page already has the timeout: what it asked for does not stay on.
            port.advertiseStop(t)
            adv = 0
            advWanted = nil
            fail(advCall, "timeout", "advertising started after the route timed out")
            advCall = -1
            return
        }
        advertising = true
        let seconds = advWanted!["seconds"] as! Int
        if advUntil == 0 && seconds > 0 { advUntil = port.now() + seconds * 1000 }
        if seconds > 0 { port.timer("advertise", t, max(0, advUntil - port.now())) }
        if advCall >= 0 { ok(advCall, BleCore.obj(("advertising", true), ("applied", applied(advWanted!)))) }
        advCall = -1
        updateHold()
        persistSoon()
    }

    func advertiseStop(_ call: Int) {
        let was = advertising
        if adv != 0 { port.advertiseStop(adv) }
        if advCall >= 0 { fail(advCall, "advertise_failed", "advertise_stop came before the platform started it") }
        advCall = -1
        adv = 0
        advertising = false
        advWanted = nil
        if was { record("advertise_end", BleCore.obj(("reason", "stopped"))) }
        updateHold()
        persistSoon()
        ok(call, BleCore.obj(("advertising", false)))
    }

    // MARK: adapter changes of the server

    /// Bluetooth left on: the server's platform objects of the old epoch are gone.
    private func serverDown() {
        if adv != 0 {
            if advertising { record("advertise_end", BleCore.obj(("reason", "adapter"))) }
            if advCall >= 0 {
                fail(advCall, "unavailable", "Bluetooth is \(adapterState)")
                advWanted = nil
            }
            advCall = -1
            adv = 0
            advertising = false
        }
        for (central, _) in centralList { endCentral(central, "adapter") }
        prepared = []
        if let p = sending { failJob(p.job, "unavailable", "Bluetooth is \(adapterState)") }
        for p in notifyQueue { failJob(p.job, "unavailable", "Bluetooth is \(adapterState)") }
        sending = nil
        notifyQueue = []
        waitingReady = false
        var waiting = addQueue
        if let a = adding { waiting.insert(a, at: 0) }
        for s in waiting where s.call >= 0 {
            services.removeAll { $0 === s }
            fail(s.call, "unavailable", "Bluetooth is \(adapterState)")
            s.call = -1
        }
        adding = nil
        addQueue = []
        for s in services { s.added = false }
    }

    /// Bluetooth is on again: re-apply the page's services and advertising (inside its duration).
    private func serverUp() {
        for s in services where !s.added && s !== adding && !addQueue.contains(where: { $0 === s }) { addQueue.append(s) }
        pumpAdds()
        if let w = advWanted, adv == 0 {
            let seconds = w["seconds"] as! Int
            if advUntil == 0 || seconds == 0 {
                startAdvertising(seconds)
            } else if advUntil > port.now() {
                startAdvertising((advUntil - port.now() + 999) / 1000)
            } else {
                advWanted = nil
                persistSoon()
            }
        }
    }

    // MARK: keep-alive (Android foreground service) and the iOS server file

    /// Links, remote centrals and advertising: what the Android keep-alive service holds the process for.
    func holdCount() -> Int { links.count + centralList.count + (advertising ? 1 : 0) }

    private func updateHold() {
        if !android { return }
        let want = keepAliveWanted && holdCount() > 0
        if want && !holdActive {
            holdGen += 1
            let err = port.keepAlive(true, holdGen)
            holdActive = err == nil
            holdReason = err.map { String($0.split(separator: " ", maxSplits: 1)[0]) }
        } else if !want && holdActive {
            holdActive = false
            holdReason = nil
            _ = port.keepAlive(false, holdGen)
        }
    }

    /// BleLinkService.onStartCommand (Android): whether start generation `g` is still the one to keep running.
    func holdCurrent(_ g: Int) -> Bool { holdActive && g == holdGen }

    /// keep_alive. `backgroundModes`: iOS only, whether the build declares the Bluetooth background modes.
    func keepAlive(_ call: Int, _ enabled: Bool, _ backgroundModes: Bool) {
        keepAliveWanted = enabled
        if !android {
            ok(call, BleCore.obj(("enabled", enabled), ("active", backgroundModes),
                                 ("reason", BleCore.nul(backgroundModes ? nil : "no_background_mode"))))
            return
        }
        updateHold()
        let reason = BleCore.nul(!enabled || holdActive ? nil : holdCount() == 0 ? "idle" : holdReason)
        ok(call, BleCore.obj(("enabled", enabled), ("active", holdActive), ("reason", reason)))
    }

    /// iOS: the server table and advertising, written to ble-server.json (nil: nothing to keep).
    func serverSnapshot() -> BleObj? {
        if services.isEmpty && advWanted == nil { return nil }
        let svcs: [Any] = services.map {
            BleCore.obj(("uuid", $0.uuid), ("primary", $0.primary), ("chars", BleCore.charList($0) as [Any]))
        }
        return BleCore.obj(("services", svcs), ("advertise", BleCore.nul(advWanted)), ("until", advUntil))
    }

    private func persistSoon() {
        if android || persistScheduled { return }
        persistScheduled = true
        port.timer("persist", 0, BleCore.persistMs)
    }

    /// iOS only. What launch does with ble-server.json once the peripheral manager settled:
    /// absent, none; unreadable, move it aside (never overwritten); readable and iOS restored the
    /// server, keep it; readable and no restore call came, an ordinary launch: delete it.
    static func serverFileAction(_ file: String, restored: Bool) -> String {
        switch file {
        case "absent": return "none"
        case "unreadable": return "move_aside"
        default: break
        }
        if restored { return "keep" }
        return "delete"
    }

    /// iOS state restoration of the server. `snapshot`: ble-server.json as JSONSerialization
    /// read it, nil when missing or unreadable. `restoredServices`: the service UUIDs iOS kept;
    /// `wasAdvertising`: whether iOS kept advertising. A restored service the file does not describe
    /// keeps its UUID with no values: reads of it answer `unlikely`. Records `restored`.
    func serverRestored(_ snapshot: [String: Any]?, restoredServices: [String], wasAdvertising: Bool) {
        let saved = (snapshot?["services"] as? [[String: Any]]) ?? []
        var lost: [Any] = []
        for raw in restoredServices {
            guard let u = BleCore.uuid(raw), service(u) == nil else { continue }
            if let s = saved.first(where: { ($0["uuid"] as? String) == u }) {
                let chars = ((s["chars"] as? [[String: Any]]) ?? []).map { c in
                    Chr(c["uuid"] as? String ?? "", c["n"] as? Int ?? 0, c["flags"] as? String ?? "",
                        (c["hex"] as? String).flatMap { BleCore.fromHex($0) })
                }
                let svc = Service(u, s["primary"] as? Bool ?? true, chars)
                svc.added = true
                services.append(svc)
            } else {
                let svc = Service(u, true, [])
                svc.added = true
                svc.lost = true
                services.append(svc)
                lost.append(u)
            }
        }
        if wasAdvertising, let a = snapshot?["advertise"] as? [String: Any] {
            let keys = ["services", "name", "manufacturerId", "manufacturerHex", "serviceDataUuid", "serviceDataHex",
                        "connectable", "mode", "seconds"]
            let p = BleObj()
            for k in keys { p[k] = a[k] ?? NSNull() }
            if !(p["seconds"] is Int) { p["seconds"] = 0 }
            advWanted = p
            nextAdv += 1
            adv = nextAdv
            advertising = true
            advUntil = snapshot?["until"] as? Int ?? 0
            if advUntil > 0 { port.timer("advertise", adv, max(0, advUntil - port.now())) }
        }
        record("restored", BleCore.obj(("services", services.map { $0.uuid } as [Any]), ("advertising", advertising),
                                       ("lost", lost)))
    }

    // MARK: timers

    func timer(_ kind: String, _ token: Int) {
        switch kind {
        case "flush":
            flush()
        case "scan":
            if token == scan && scan != 0 {
                port.scanStop(scan)
                endScan("elapsed")
            } else {
                stale("scan timer \(token)")
            }
        case "connect":
            for l in orderedLinks() where l.gen == token && !l.closed && l.state == "connecting" {
                closeLink(l, "timeout", down: false)
                return
            }
            stale("connect timer \(token)")
        case "pending":
            for l in orderedLinks() where l.pendingTimer == token && !l.closed && l.state == "connecting" {
                closeLink(l, "timeout", down: false)
                return
            }
            stale("pending timer \(token)")
        case "op":
            for l in orderedLinks() {
                if let o = l.inFlight, o.op == token, !l.closed {
                    l.inFlight = nil
                    settle(l, o, "gatt_error", "the operation got no answer in \(BleCore.opMs / 1000) s", nil)
                    closeLink(l, "op_timeout", down: false)
                    return
                }
            }
            stale("op timer \(token)")
        case "close":
            for id in closingOrder where closing[id]!.gen == token {
                port.release(id, token)
                finishClosing(id, confirmed: false)
                return
            }
            stale("close timer \(token)")
        case "wait":
            for id in closingOrder {
                let c = closing[id]!
                if let w = c.waiter, w.token == token {
                    c.waiter = nil
                    fail(w.call, "connect_timeout", "the previous connection did not close in time")
                    return
                }
            }
            stale("wait timer \(token)")
        case "service":
            if let s = adding, s.token == token {
                adding = nil
                port.serviceRemove(s.uuid)
                if s.call >= 0 {
                    services.removeAll { $0 === s }
                    fail(s.call, "gatt_error", "the platform did not confirm the service in \(BleCore.opMs / 1000) s")
                    s.call = -1
                }
                pumpAdds()
            } else {
                stale("service timer \(token)")
            }
        case "notify":
            if let p = sending, p.packet == token {
                sending = nil
                failJob(p.job, "gatt_error", "the notification got no answer in \(BleCore.opMs / 1000) s")
                resolve(p, false)
                pumpNotify()
            } else {
                stale("notify timer \(token)")
            }
        case "advertise_start":
            if token == adv && !advertising {
                port.advertiseStop(token)
                adv = 0
                advWanted = nil
                if advCall >= 0 {
                    fail(advCall, "advertise_failed", "the platform did not answer the advertising start")
                } else {
                    record("advertise_end", BleCore.obj(("reason", "failed")))
                }
                advCall = -1
            } else {
                stale("advertise_start timer \(token)")
            }
        case "advertise":
            if token == adv && advertising {
                port.advertiseStop(token)
                adv = 0
                advertising = false
                advWanted = nil
                record("advertise_end", BleCore.obj(("reason", "elapsed")))
                updateHold()
                persistSoon()
            } else {
                stale("advertise timer \(token)")
            }
        case "persist":
            persistScheduled = false
            port.persist(serverSnapshot())
        default:
            stale("timer \(kind)")
        }
    }

    // MARK: journal

    func events(_ call: Int, _ after: Int, _ max: Int) {
        var out: [Any] = []
        var next = after
        var i = journalHead
        while i < journal.count && out.count < max {
            let r = journal[i]
            i += 1
            if r.seq <= after { continue }
            out.append(BleCore.obj(("seq", r.seq), ("t", r.t), ("event", r.event), ("data", r.data)))
            next = r.seq
        }
        ok(call, BleCore.obj(("records", out), ("next", next), ("dropped", dropped), ("run", run)))
    }
}
