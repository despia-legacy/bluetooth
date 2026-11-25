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
    /// `options`: the scan options the page gave beyond services, duplicates and mode (keys as in
    /// `scanOptionKeys`); the radio applies what its platform offers (`scanApplied` says which).
    func scanStart(_ scan: Int, _ services: [String], _ duplicates: Bool, _ mode: String, _ options: BleObj) -> String?
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
    /// The key of the first discovered characteristic of link `gen` that takes a write with response
    /// (`withResponse`) or without one; nil when none (the `raw` route).
    func writable(_ id: String, _ gen: Int, _ withResponse: Bool) -> String?
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

    /// Answer the central's request `request` (a read or write of a characteristic with flag a) with an
    /// ATT outcome (`attStatuses`), the offset and, for a read, the value. nil when handed over, else "code message".
    func attRespond(_ epoch: Int, _ request: Int, _ status: String, _ offset: Int, _ data: [UInt8]?) -> String?
    /// Publish an L2CAP channel as token `t`. nil when accepted (l2capPublished follows).
    func l2capPublish(_ epoch: Int, _ t: Int, _ encrypted: Bool) -> String?
    func l2capUnpublish(_ psm: Int)
    /// Open channel `channel` to `id` on `psm`. nil when accepted (l2capOpened follows).
    func l2capOpen(_ epoch: Int, _ channel: Int, _ id: String, _ psm: Int, _ encrypted: Bool) -> String?
    /// Queue bytes on an open channel. nil when accepted, else "code message".
    func l2capSend(_ channel: Int, _ data: [UInt8]) -> String?
    /// Close a channel or abandon its opening; no callback follows.
    func l2capClose(_ channel: Int)
    /// Android: start advertising set `set` (the iOS core never asks). nil when accepted.
    func advertiseSetStart(_ epoch: Int, _ set: Int, _ params: BleObj) -> String?
    func advertiseSetStop(_ set: Int)

    // Android restoration (kinds and answers as BleCore.java's Port; the iOS core never asks).
    func wakeStart(_ filters: BleObj, _ mode: String) -> String?
    func wakeStop()
    func wakeSave(_ filters: BleObj?)
    func associate(_ request: Int, _ params: BleObj) -> String?
    /// The app's associations as records, or "code message".
    func associations() -> Any
    func disassociate(_ association: Int) -> String?
    func presence(_ start: Bool, _ association: Int) -> String?
}

/// The iOS radio has no wake scan and no presence observation: the core answers before asking. The
/// associate family is iOS's AccessorySetupKit (the port, `BleAccessories`), so it has no default.
extension BlePort {
    func wakeStart(_ filters: BleObj, _ mode: String) -> String? { "platform_limit \(BleCore.wakeLimit)" }
    func wakeStop() {}
    func wakeSave(_ filters: BleObj?) {}
    func presence(_ start: Bool, _ association: Int) -> String? { "platform_limit \(BleCore.presenceLimit)" }
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
    /// The scan's own filters, applied here on every platform: advertised names, and a manufacturer id
    /// with an optional data prefix.
    private var scanNames: [String] = []
    private var scanManufacturer = -1
    private var scanManufacturerPrefix: [UInt8] = []
    private var devices: [String: BleObj] = [:]
    private var deviceOrder: [String] = []
    private var pendingDevices: [Any] = []
    private var journal: [(seq: Int, t: Int, event: String, data: BleObj, size: Int)] = []
    private var journalHead = 0
    private var journalSize = 0
    private(set) var dropped = 0
    private var pendingValues: [BleObj] = []
    private var flushScheduled = false
    /// The disk-durable journal: the last seq handed to the port, records written since the last rewrite.
    private var persistedSeq = 0
    private var persistedSinceRewrite = 0
    /// The journal of the previous app process, read back from disk at launch.
    private(set) var previousRun: String?
    private var previousRecords: [BleObj] = []
    private var previousDropped = 0

    final class Link {
        let id: String
        let gen: Int
        var state = "connecting"
        var auto = false
        var background = false
        var mtu = 23
        var connectCall = -1
        /// A page `connect` with `seconds` 0: the attempt waits for the device without a time limit
        /// (the route answered at once with `connecting`).
        var unbounded = false
        /// The system reconnects this link itself (iOS 17 CBConnectPeripheralOptionEnableAutoReconnect):
        /// the attempt started when the platform reported the drop with `reconnecting`.
        var system = false
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
        /// The `raw` route: the reply names the characteristic the radio chose.
        var raw = false

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

    /// Exactly one of hex, b64 and text (UTF-8) decoded; nil when none, more than one, or malformed.
    static func bytes(_ hex: String?, _ b64: String?, _ text: String? = nil) -> [UInt8]? {
        let given = (hex != nil ? 1 : 0) + (b64 != nil ? 1 : 0) + (text != nil ? 1 : 0)
        if given != 1 { return nil }
        if let t = text { return Array(t.utf8) }
        return hex != nil ? fromHex(hex) : fromB64(b64)
    }

    /// Comma-separated names (each 1 to 248 UTF-8 bytes, the GAP name limit), at most 10; empty
    /// when missing; nil when malformed.
    static func nameList(_ s: String?) -> [String]? {
        var out: [String] = []
        guard let s = s, !s.isEmpty else { return out }
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            let n = String(part)
            if n.isEmpty || n.utf8.count > 248 { return nil }
            if !out.contains(n) { out.append(n) }
        }
        return out.count > 10 ? nil : out
    }

    /// PHY names of the `phy` route (`1m`, `2m`, `coded`), comma-separated; nil when malformed or empty.
    static func phyList(_ s: String?) -> [String]? {
        guard let s = s, !s.isEmpty else { return nil }
        var out: [String] = []
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            let p = String(part)
            if !["1m", "2m", "coded"].contains(p) { return nil }
            if !out.contains(p) { out.append(p) }
        }
        return out
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

    /// The disk-durable journal, asked by the extension on its own timer after events: the records
    /// ({seq, t, event, data}) to append to this run's file since the last call, or, once the file
    /// holds twice the window's record count, the whole window to replace it with (`rewrite`), so
    /// the file stays bounded. Nil when there is nothing new.
    func journalToPersist() -> (records: [BleObj], rewrite: Bool)? {
        var out: [BleObj] = []
        var rewrite = false
        if persistedSinceRewrite >= BleCore.journalRecords * 2 {
            rewrite = true
            for i in journalHead..<journal.count { out.append(journalRecord(journal[i])) }
            persistedSinceRewrite = out.count
        } else {
            for i in journalHead..<journal.count where journal[i].seq > persistedSeq { out.append(journalRecord(journal[i])) }
            persistedSinceRewrite += out.count
        }
        if journal.count > journalHead { persistedSeq = journal[journal.count - 1].seq }
        return out.isEmpty && !rewrite ? nil : (out, rewrite)
    }

    private func journalRecord(_ r: (seq: Int, t: Int, event: String, data: BleObj, size: Int)) -> BleObj {
        BleCore.obj(("seq", r.seq), ("t", r.t), ("event", r.event), ("data", r.data))
    }

    /// Launch: the previous process's journal as its file held it (records {seq, t, event, data},
    /// oldest first). Only the newest `journalRecords` are kept; `events` with `run` reads them.
    func loadPrevious(_ run: String, _ records: [BleObj]) {
        previousRun = run
        previousDropped = max(0, records.count - BleCore.journalRecords)
        previousRecords = Array(records.suffix(BleCore.journalRecords))
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
        if !pendingL2cap.isEmpty {
            let n = min(BleCore.batchMax, pendingL2cap.count)
            let batch: [Any] = Array(pendingL2cap[0..<n])
            pendingL2cap.removeFirst(n)
            port.emit("l2cap_data", BleCore.obj(("records", batch), ("dropped", dropped)))
            if !pendingL2cap.isEmpty { scheduleFlush() }
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
                    ("centrals", centralList.count), ("keepAlive", keepAliveWanted), ("epoch", epoch), ("run", run),
                    ("previousRun", BleCore.nul(previousRun)))
    }

    // MARK: scan

    /// The scan options passed through to the radio, by route parameter name.
    static let scanOptionKeys = ["legacy", "phy", "report_delay", "callback_type", "match", "matches", "solicited"]

    /// What this platform applies of the given scan options: Android's ScanSettings (legacy, phy,
    /// report_delay, callback, match, matches); iOS's solicited service UUIDs. Names and the
    /// manufacturer filter are the core's own, so they apply on both.
    func scanApplied(_ options: BleObj, names: Bool, manufacturer: Bool) -> BleObj {
        let out = BleObj()
        if names { out["names"] = true }
        if manufacturer { out["manufacturer"] = true }
        for k in options.keys { out[k] = k == "solicited" ? !android : android }
        return out
    }

    func scanStart(_ call: Int, _ servicesCsv: String?, _ seconds: Int, _ duplicates: Bool, _ mode: String, _ background: Bool,
                   names namesCsv: String? = nil, manufacturerId: Int = -1, manufacturerHex: String? = nil,
                   options: BleObj = BleObj()) {
        guard let services = BleCore.uuidList(servicesCsv) else {
            fail(call, "bad_value", "services must be up to 20 UUIDs")
            return
        }
        guard let names = BleCore.nameList(namesCsv) else {
            fail(call, "bad_value", "names must be up to 10 comma-separated names of 1 to 248 bytes")
            return
        }
        let prefix = manufacturerHex.flatMap { BleCore.fromHex($0) }
        if manufacturerId > 0xFFFF || (manufacturerHex != nil && (prefix == nil || manufacturerId < 0)) {
            fail(call, "bad_value", "manufacturer_id is 0 to 65535; manufacturer_hex is hex bytes and needs manufacturer_id")
            return
        }
        for k in options.keys where !BleCore.scanOptionKeys.contains(k) {
            fail(call, "bad_value", "unknown scan option \(k); the options are " + BleCore.scanOptionKeys.joined(separator: ", "))
            return
        }
        if let sol = options["solicited"] as? String {
            guard let list = BleCore.uuidList(sol) else {
                fail(call, "bad_value", "solicited must be up to 20 UUIDs")
                return
            }
            options["solicited"] = list as [Any]
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
        // Set before the port call: the radio builds its platform filters from them.
        scanNames = names
        scanManufacturer = manufacturerId
        scanManufacturerPrefix = prefix ?? []
        if let err = port.scanStart(s, services, duplicates, mode, options) {
            refused(call, err)
            return
        }
        scan = s
        lastScan = s
        devices = [:]
        deviceOrder = []
        filtered = !services.isEmpty
        if seconds > 0 { port.timer("scan", s, seconds * 1000) }
        ok(call, BleCore.obj(("scan", s),
                             ("applied", scanApplied(options, names: !names.isEmpty, manufacturer: manufacturerId >= 0))))
    }

    /// Whether an advertisement passes the scan's own name and manufacturer filters.
    private func matches(_ adv: BleObj) -> Bool {
        if !scanNames.isEmpty {
            guard let n = adv["name"] as? String, scanNames.contains(n) else { return false }
        }
        if scanManufacturer >= 0 {
            let list = (adv["manufacturer"] as? [Any]) ?? []
            let hit = list.contains { m in
                guard let o = m as? BleObj, o["id"] as? Int == scanManufacturer,
                      let b = BleCore.fromHex(o["hex"] as? String) else { return false }
                return b.count >= scanManufacturerPrefix.count && Array(b[0..<scanManufacturerPrefix.count]) == scanManufacturerPrefix
            }
            if !hit { return false }
        }
        return true
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
        if !matches(adv) { return }
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

    /// `seconds` 0: the attempt waits for the device without a time limit (iOS keeps a pending
    /// connection, Android connects with autoConnect); the route answers at once with `connecting`
    /// and the `link` event reports the connection.
    func connect(_ call: Int, _ id: String?, _ auto: Bool, _ seconds: Int) {
        guard checkId(call, id), let id = id else { return }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        if seconds == 0 {
            if links[id] != nil || closing[id] != nil {
                fail(call, "busy", "this device is linked, connecting or closing")
                return
            }
            startLink(id, auto: auto, call: -1, seconds: 0, background: true, wanted: [], unbounded: true)
            guard let l = links[id] else {
                fail(call, lastRefusal.0, lastRefusal.1)
                return
            }
            ok(call, BleCore.obj(("id", id), ("link", l.gen), ("state", "connecting"), ("mtu", l.mtu)))
            return
        }
        if let l = links[id] {
            // A pending attempt no call owns (restored by iOS, or an automatic reconnect) is
            // adopted: this call owns it from now on, with its own timeout, and the page's `auto` wins.
            if l.state == "connecting" && l.connectCall < 0 && !l.closed {
                l.connectCall = call
                l.auto = auto
                l.background = false
                l.unbounded = false
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

    /// The last port refusal of a connect no call owned ("code", "message").
    private var lastRefusal = ("connect_failed", "")

    private func startLink(_ id: String, auto: Bool, call: Int, seconds: Int, background: Bool, wanted: [String],
                           unbounded: Bool = false, system: Bool = false) {
        nextGen += 1
        let l = Link(id, nextGen)
        l.auto = auto
        l.background = background
        l.unbounded = unbounded
        l.system = system
        l.connectCall = call
        for k in wanted { l.addWanted(k) }
        putLink(l)
        if let err = port.connect(id, l.gen, auto, background) {
            removeLink(id)
            l.closed = true
            if let sp = err.firstIndex(of: " ") {
                lastRefusal = (String(err[..<sp]), String(err[err.index(after: sp)...]))
            } else {
                lastRefusal = (err, "")
            }
            refused(call, err)
            return
        }
        if call >= 0 { port.timer("connect", l.gen, seconds * 1000) }
        if unbounded {
            record("link", BleCore.obj(("id", id), ("link", l.gen), ("state", "connecting"), ("reason", "requested")))
        } else if background {
            record("link", BleCore.obj(("id", id), ("link", l.gen), ("state", "reconnecting"), ("reason", system ? "system" : "auto")))
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
    /// failed connect call's message and the `link` record unchanged. `reconnecting`: the platform
    /// is reconnecting the device itself (iOS 17 `isReconnecting`); the link closes as any drop does
    /// and a new attempt waits for that reconnect, as an `auto` link's would, without making the
    /// link `auto`.
    func disconnected(_ id: String, _ gen: Int, _ reason: String, error: BleObj? = nil, reconnecting: Bool = false) {
        let l = links[id]
        if current(l, gen) {
            _ = closeLink(l!, BleCore.errorReason(error, reason), down: true, error: error, systemReconnect: reconnecting)
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
    func closeLink(_ l: Link, _ reason: String, down: Bool, error: BleObj? = nil, systemReconnect: Bool = false) -> Bool {
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
        if (l.auto || systemReconnect) && reason != "requested" && on {
            if let c = closing[l.id] {
                c.reconnect = true
                c.wanted = l.wanted
            } else {
                startLink(l.id, auto: l.auto, call: -1, seconds: 0, background: true, wanted: l.wanted,
                          system: systemReconnect && !l.auto)
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
               _ hexValue: String?, _ b64Value: String?, _ response: Bool, text: String? = nil) {
        guard let l = connectedLink(call, id) else { return }
        guard let k = target(call, service, sn, chr, cn) else { return }
        guard let data = writeData(call, hexValue, b64Value, text) else { return }
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

    /// The bytes of a write (exactly one of hex, b64 and text), or nil after failing the call.
    private func writeData(_ call: Int, _ hexValue: String?, _ b64Value: String?, _ text: String?) -> [UInt8]? {
        guard let data = BleCore.bytes(hexValue, b64Value, text) else {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed")
            return nil
        }
        if data.count > BleCore.writeMax {
            fail(call, "too_long", "\(data.count) bytes; at most \(BleCore.writeMax)")
            return nil
        }
        return data
    }

    /// The `raw` route: bytes to the first discovered characteristic that takes the write
    /// (with response by default). The reply names the characteristic.
    func raw(_ call: Int, _ id: String?, _ hexValue: String?, _ b64Value: String?, _ text: String?, _ response: Bool) {
        guard let l = connectedLink(call, id) else { return }
        guard let data = writeData(call, hexValue, b64Value, text) else { return }
        guard let k = port.writable(l.id, l.gen, response) else {
            fail(call, "not_found", "no discovered characteristic takes a write " + (response ? "with" : "without")
                 + " response (run discover first)")
            return
        }
        let o = Op(call, response ? "write" : "wnr")
        o.key = k
        o.data = data
        o.raw = true
        enqueue(call, l, o)
    }

    /// Android requestConnectionPriority: `level` balanced, high, low_power or dck.
    func priority(_ call: Int, _ id: String?, _ level: String) {
        guard let l = connectedLink(call, id) else { return }
        if !android {
            fail(call, "platform_limit", "iOS has no API to request a connection priority or interval; the system and the peripheral set it")
            return
        }
        let o = Op(call, "priority")
        o.key = level
        enqueue(call, l, o)
    }

    /// Android setPreferredPhy (tx and rx given, `coded` none, s2 or s8) or readPhy (neither given).
    func phy(_ call: Int, _ id: String?, _ tx: String?, _ rx: String?, _ coded: String) {
        guard let l = connectedLink(call, id) else { return }
        if !android {
            fail(call, "platform_limit", "iOS has no API to read or set the LE PHY; the system chooses it")
            return
        }
        if tx == nil && rx == nil {
            enqueue(call, l, Op(call, "phy_read"))
            return
        }
        guard let t = BleCore.phyList(tx ?? rx), let r = BleCore.phyList(rx ?? tx) else {
            fail(call, "bad_value", "tx and rx are comma-separated PHYs: 1m, 2m, coded")
            return
        }
        let o = Op(call, "phy_set")
        o.key = t.joined(separator: ",") + "/" + r.joined(separator: ",") + "/" + coded
        enqueue(call, l, o)
    }

    /// The link's PHY changed (Android onPhyUpdate). It completes a phy_set in flight; otherwise it is a `phy` event.
    func phyChanged(_ id: String, _ gen: Int, _ tx: String, _ rx: String, _ code: String?) {
        guard let l = live(id, gen, "phy") else { return }
        if let o = l.inFlight, o.kind == "phy_set" {
            l.inFlight = nil
            settle(l, o, code.map { _ in "gatt_error" }, code.map { "the PHY update failed: \($0)" },
                   BleCore.obj(("tx", tx), ("rx", rx)))
            pump(l)
            return
        }
        if code == nil { record("phy", BleCore.obj(("id", id), ("link", gen), ("tx", tx), ("rx", rx))) }
    }

    /// An event the extension produces outside the core's state (bond changes, for one): kept in the
    /// journal like every event.
    func external(_ event: String, _ data: BleObj) {
        record(event, data)
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
                                   ("reason", l.system ? "system" : l.background && !l.unbounded ? "auto" : "requested"),
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
        case "write", "wnr":
            let r = BleCore.obj(("written", o.data!.count), ("chunks", o.kind == "wnr" ? o.chunks : 1))
            if o.raw, let k = o.key {
                let p = k.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
                r.putAll(BleCore.obj(("service", p[0]), ("char", p[2]), ("service_n", Int(p[1])!), ("char_n", Int(p[3])!),
                                     ("response", o.kind == "write")))
            }
            ok(o.call, r)
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
    /// `uuid~flags~hex`, comma-separated, at most 16; equal UUIDs are numbered in order. Flag a: the page
    /// answers the characteristic's reads and writes (att_request, respond). nil when malformed.
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
                if !"rwcniRWa".contains(c) || letters.contains(c) { return nil }
                letters.insert(c)
            }
            if !flags.contains(where: { "rwcni".contains($0) }) { return nil }
            if flags.contains("R") && !flags.contains("r") { return nil }
            if flags.contains("W") && !flags.contains("w") && !flags.contains("c") { return nil }
            if flags.contains("a") && !flags.contains("r") && !flags.contains("w") && !flags.contains("c") { return nil }
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

    func valueSet(_ call: Int, _ serviceUUID: String?, _ chrUUID: String?, _ cn: Int, _ hexValue: String?, _ b64Value: String?,
                  text: String? = nil) {
        guard let c = chr(serviceUUID, chrUUID, cn) else {
            fail(call, "not_found", "no such characteristic in the table")
            return
        }
        guard let data = BleCore.bytes(hexValue, b64Value, text) else {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed")
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
                _ central: String?, text: String? = nil) {
        guard let c = chr(serviceUUID, chrUUID, cn) else {
            fail(call, "not_found", "no such characteristic in the table")
            return
        }
        guard let data = BleCore.bytes(hexValue, b64Value, text) else {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed")
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
        dropRequests(central, reason)
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
    /// not_permitted, invalid_offset, unlikely or stale; for a characteristic with flag a, pending and the
    /// request number: the page answers it with respond (or the core answers unlikely after attAnswerMs).
    func readRequest(_ e: Int, _ central: String, _ mtu: Int, _ key: String, _ offset: Int) -> BleObj {
        if !serverCurrent(e, "read_request") { return BleCore.obj(("status", "stale")) }
        guard let c = chrOf(key) else { return BleCore.obj(("status", lostService(key) ? "unlikely" : "not_found")) }
        seen(central, mtu)
        if !c.has("r") { return BleCore.obj(("status", "not_permitted")) }
        if c.has("a") {
            let p = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
            let view = BleCore.obj(("kind", "read"), ("central", central), ("service", p[0]), ("char", p[2]),
                                   ("char_n", Int(p[3])!), ("offset", offset))
            return BleCore.obj(("status", "pending"), ("request", openRequest(e, central, "read", offset, view, [])))
        }
        guard let v = c.value else { return BleCore.obj(("status", "unlikely")) }
        if offset > v.count { return BleCore.obj(("status", "invalid_offset")) }
        return BleCore.obj(("status", "ok"), ("hex", BleCore.hex(Array(v[offset...]))))
    }

    /// Write requests of one central, applied all or none (iOS delivers a batch and answers it once;
    /// Android passes one). Each is {key, offset, hex}, with `response: false` for Android's responseNeeded
    /// false. `prepare`: an Android prepared write. When the batch writes a characteristic with flag a and
    /// wants a response, "pending N": the page answers request N with respond, for the whole batch.
    func writeRequests(_ e: Int, _ central: String, _ mtu: Int, _ reqs: [BleObj], _ prepare: Bool) -> String {
        if !serverCurrent(e, "write_request") { return "stale" }
        var next: [(String, [UInt8])] = []
        var asked: [Any] = []
        var response = true
        for r in reqs {
            let key = r["key"] as! String
            guard let c = chrOf(key) else { return "not_found" }
            if !c.has("w") && !c.has("c") { return "not_permitted" }
            guard let data = BleCore.fromHex(r["hex"] as? String) else { return "invalid_length" }
            if (r["response"] as? Bool) == false { response = false }
            if c.has("a") && !prepare {
                let offset = r["offset"] as! Int
                if offset + data.count > BleCore.writeMax { return "invalid_length" }
                asked.append(BleCore.writeView(key, offset, data))
                continue
            }
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
        if !asked.isEmpty {
            let view = BleCore.obj(("kind", "write"), ("central", central), ("writes", asked))
            if response { return "pending \(openRequest(e, central, "write", 0, view, next))" }
            // No answer travels back to the central: the page gets the write, and nothing waits.
            let rec = BleCore.obj(("request", NSNull()), ("state", "unanswered"))
            rec.putAll(view)
            rec["mtu"] = centralMtu(of: central).map { $0 as Any } ?? NSNull()
            record("att_request", rec)
        }
        for (slot, v) in next {
            if prepare {
                if let i = prepared.firstIndex(where: { $0.0 == slot }) { prepared[i].1 = v } else { prepared.append((slot, v)) }
            } else {
                commit(central, slot, v)
            }
        }
        return "ok"
    }

    /// Android onExecuteWrite: commit (true) or drop this central's prepared writes. When a prepared
    /// characteristic has flag a, "pending N": the page answers the assembled values with respond.
    func executeWrite(_ e: Int, _ central: String, _ execute: Bool) -> String {
        if !serverCurrent(e, "execute_write") { return "stale" }
        let mine = prepared.filter { $0.0.hasPrefix(central + "|") }
        prepared.removeAll { $0.0.hasPrefix(central + "|") }
        var asked: [Any] = []
        var commits: [(String, [UInt8])] = []
        if execute {
            for (slot, v) in mine {
                let key = String(slot.dropFirst(central.count + 1))
                if let c = chrOf(key), c.has("a") { asked.append(BleCore.writeView(key, 0, v)) } else { commits.append((key, v)) }
            }
        }
        if !asked.isEmpty {
            return "pending \(openRequest(e, central, "write", 0, BleCore.obj(("kind", "write"), ("central", central), ("writes", asked)), commits))"
        }
        for (key, v) in commits { commit(central, key, v) }
        return "ok"
    }

    // MARK: page-answered requests (characteristics with flag a)

    /// How long a request waits for the page: under ATT's 30 s transaction timeout (Bluetooth Core 5.4,
    /// Vol 3, Part F, 3.3.3), after which the central drops the link; the core answers unlikely first.
    static let attAnswerMs = 25000
    /// The ATT outcomes respond takes; each radio maps them to its platform's codes.
    static let attStatuses = ["ok", "not_permitted", "invalid_offset", "invalid_length", "insufficient_authentication",
                              "insufficient_authorization", "insufficient_encryption", "not_supported",
                              "insufficient_resources", "unlikely"]

    final class Req {
        let id: Int, epoch: Int, offset: Int
        let central: String, kind: String
        /// Writes in the same batch to characteristics without flag a: committed when the page answers ok.
        let commits: [(String, [UInt8])]

        init(_ id: Int, _ epoch: Int, _ central: String, _ kind: String, _ offset: Int, _ commits: [(String, [UInt8])]) {
            self.id = id
            self.epoch = epoch
            self.central = central
            self.kind = kind
            self.offset = offset
            self.commits = commits
        }
    }

    private var requests: [Req] = []
    private var nextReq = 0

    static func writeView(_ key: String, _ offset: Int, _ data: [UInt8]) -> BleObj {
        let p = key.split(whereSeparator: { $0 == "#" || $0 == "/" }).map(String.init)
        return obj(("service", p[0]), ("char", p[2]), ("char_n", Int(p[3])!), ("offset", offset), ("hex", hex(data)))
    }

    private func openRequest(_ e: Int, _ central: String, _ kind: String, _ offset: Int, _ view: BleObj,
                             _ commits: [(String, [UInt8])]) -> Int {
        nextReq += 1
        let id = nextReq
        requests.append(Req(id, e, central, kind, offset, commits))
        let rec = BleCore.obj(("request", id), ("state", "open"))
        rec.putAll(view)
        rec["mtu"] = centralMtu(of: central).map { $0 as Any } ?? NSNull()
        record("att_request", rec)
        port.timer("att", id, BleCore.attAnswerMs)
        return id
    }

    /// respond: the page's answer to request `request`. `status` nil means ok; a read answered ok carries
    /// exactly one of hex, b64 and text (the value from the request's offset); `offset` below 0 means the request's own.
    func respond(_ call: Int, _ request: Int, _ status: String?, _ hexValue: String?, _ b64Value: String?, _ text: String?,
                 _ offset: Int) {
        guard let i = requests.firstIndex(where: { $0.id == request }) else {
            fail(call, "not_found", "no open request \(request): it was answered, it expired or its central left")
            return
        }
        let q = requests[i]
        let st = status ?? "ok"
        if !BleCore.attStatuses.contains(st) {
            fail(call, "bad_value", "status must be one of " + BleCore.attStatuses.joined(separator: ", "))
            return
        }
        var data: [UInt8]?
        if q.kind == "read" && st == "ok" {
            guard let d = BleCore.bytes(hexValue, b64Value, text) else {
                fail(call, "bad_value", "a read answered ok carries exactly one of hex, b64 and text, well formed")
                return
            }
            if d.count > BleCore.writeMax {
                fail(call, "too_long", "\(d.count) bytes; at most \(BleCore.writeMax)")
                return
            }
            data = d
        } else if hexValue != nil || b64Value != nil || text != nil {
            fail(call, "bad_value", "only a read answered ok carries a value")
            return
        }
        requests.remove(at: i)
        if let err = port.attRespond(q.epoch, request, st, offset < 0 ? q.offset : offset, data) {
            refused(call, err)
            return
        }
        if st == "ok" { for (key, v) in q.commits { commit(q.central, key, v) } }
        record("att_request", BleCore.obj(("request", request), ("state", "answered"), ("status", st)))
        ok(call, BleCore.obj(("request", request), ("status", st), ("bytes", data?.count ?? 0)))
    }

    /// The open requests of `central` end without an answer: the central left (or the adapter went off).
    private func dropRequests(_ central: String, _ reason: String) {
        let gone = requests.filter { $0.central == central }
        requests.removeAll { $0.central == central }
        for q in gone { record("att_request", BleCore.obj(("request", q.id), ("state", "dropped"), ("reason", reason))) }
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
                        _ serviceDataUuid: String?, _ serviceDataHex: String?, _ connectable: Bool, _ mode: String, _ seconds: Int,
                        txPower: String? = nil, includeTxPower: Bool? = nil) {
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
        // Android's AdvertiseSettings tx power level and AdvertiseData tx power field; only when given,
        // so a request without them keeps the platform default.
        if let t = txPower { p["txPower"] = t }
        if let i = includeTxPower { p["includeTxPower"] = i }
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
    static func nul(_ v: Any?) -> Any { v ?? NSNull() }

    /// What this platform really advertises of the request.
    private func applied(_ p: BleObj) -> BleObj {
        let a = BleCore.obj(("name", BleCore.nul(BleCore.isSet(p["name"]) ? (android ? "adapter" : "given") : nil)),
                            ("manufacturer", android && BleCore.isSet(p["manufacturerId"])),
                            ("serviceData", android && BleCore.isSet(p["serviceDataUuid"])),
                            ("connectable", android ? p["connectable"]! : true as Any),
                            ("mode", android ? p["mode"]! : NSNull() as Any))
        if BleCore.isSet(p["txPower"]) { a["txPower"] = android ? p["txPower"]! : NSNull() as Any }
        if BleCore.isSet(p["includeTxPower"]) { a["includeTxPower"] = android && (p["includeTxPower"] as? Bool ?? false) }
        return a
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

    // MARK: L2CAP connection-oriented channels

    /// Bytes in one l2cap_send: the bridge carries a string of at most 4096 characters (hex 2048 bytes).
    static let l2capSendMax = 2048
    static let l2capPsm = "psm must be an LE PSM, 1 to 255 (Bluetooth Core 5.4, Vol 3, Part A, 4.22)"

    final class Channel {
        let n: Int, psm: Int
        let role: String, peer: String
        var state: String
        var call = -1

        init(_ n: Int, _ role: String, _ peer: String, _ psm: Int, _ state: String) {
            self.n = n
            self.role = role
            self.peer = peer
            self.psm = psm
            self.state = state
        }
    }

    private var channels: [Channel] = []
    /// Publishes in flight, by token.
    private var publishing: [(t: Int, call: Int, encrypted: Bool)] = []
    /// Published PSMs and whether each needs encryption.
    private var published: [(psm: Int, encrypted: Bool)] = []
    private var pendingL2cap: [BleObj] = []
    private var nextChannel = 0, nextPublish = 0

    private func channel(_ n: Int) -> Channel? { channels.first { $0.n == n } }

    private func channelView(_ ch: Channel) -> BleObj {
        BleCore.obj(("channel", ch.n), ("state", ch.state), ("role", ch.role), ("peer", ch.peer), ("psm", ch.psm))
    }

    /// l2cap_publish: the peripheral role's listening channel; the platform picks the PSM.
    func l2capPublish(_ call: Int, _ encrypted: Bool) {
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        nextPublish += 1
        let t = nextPublish
        if let err = port.l2capPublish(epoch, t, encrypted) {
            refused(call, err)
            return
        }
        publishing.append((t, call, encrypted))
        port.timer("l2cap_publish", t, BleCore.opMs)
    }

    func l2capPublished(_ e: Int, _ t: Int, _ psm: Int, _ code: String?) {
        if !serverCurrent(e, "l2cap_published") { return }
        guard let i = publishing.firstIndex(where: { $0.t == t }) else {
            stale("l2cap_published \(t)")
            return
        }
        let p = publishing.remove(at: i)
        if let code = code {
            fail(p.call, "l2cap_failed", "the platform did not publish the channel: \(code)")
            return
        }
        if p.call >= 0 && !port.isActive(p.call) {
            port.l2capUnpublish(psm)
            fail(p.call, "timeout", "the channel was published after the route timed out")
            return
        }
        published.append((psm, p.encrypted))
        ok(p.call, BleCore.obj(("psm", psm), ("encrypted", p.encrypted)))
    }

    func l2capUnpublish(_ call: Int, _ psm: Int) {
        guard let i = published.firstIndex(where: { $0.psm == psm }) else {
            fail(call, "not_found", "no published channel on psm \(psm)")
            return
        }
        published.remove(at: i)
        port.l2capUnpublish(psm)
        ok(call, BleCore.obj(("psm", psm), ("published", false)))
    }

    /// A central opened a channel to a published PSM. Returns the channel number, or -1 (the radio closes it).
    func l2capIncoming(_ e: Int, _ psm: Int, _ peer: String) -> Int {
        if !serverCurrent(e, "l2cap_incoming") { return -1 }
        if !published.contains(where: { $0.psm == psm }) {
            stale("l2cap_incoming psm \(psm)")
            return -1
        }
        nextChannel += 1
        let ch = Channel(nextChannel, "peripheral", peer, psm, "open")
        channels.append(ch)
        record("l2cap", channelView(ch))
        updateHold()
        return ch.n
    }

    /// l2cap_open: the central role's channel to `id` on `psm`, within `seconds`.
    func l2capOpen(_ call: Int, _ id: String?, _ psm: Int, _ encrypted: Bool, _ seconds: Int) {
        guard let id = id, BleCore.isId(id, android ? "android" : "ios") else {
            fail(call, "bad_value", "id must be a device id from a scan or a link")
            return
        }
        if psm < 1 || psm > 255 {
            fail(call, "bad_value", BleCore.l2capPsm)
            return
        }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        nextChannel += 1
        let ch = Channel(nextChannel, "central", id, psm, "opening")
        if let err = port.l2capOpen(epoch, ch.n, id, psm, encrypted) {
            refused(call, err)
            return
        }
        ch.call = call
        channels.append(ch)
        port.timer("l2cap_open", ch.n, (seconds > 0 ? seconds : 10) * 1000)
    }

    func l2capOpened(_ e: Int, _ n: Int, _ code: String?) {
        if !serverCurrent(e, "l2cap_opened") { return }
        guard let ch = channel(n), ch.state == "opening" else {
            stale("l2cap_opened \(n)")
            return
        }
        let call = ch.call
        ch.call = -1
        if let code = code {
            channels.removeAll { $0 === ch }
            fail(call, "l2cap_failed", "the channel did not open: \(code)")
            return
        }
        if call >= 0 && !port.isActive(call) {
            channels.removeAll { $0 === ch }
            port.l2capClose(n)
            fail(call, "timeout", "the channel opened after the route timed out")
            return
        }
        ch.state = "open"
        record("l2cap", channelView(ch))
        updateHold()
        ok(call, BleCore.obj(("channel", n), ("psm", ch.psm), ("id", ch.peer)))
    }

    func l2capSend(_ call: Int, _ n: Int, _ hexValue: String?, _ b64Value: String?, _ text: String?) {
        guard let ch = channel(n) else {
            fail(call, "not_found", "no channel \(n)")
            return
        }
        if ch.state != "open" {
            fail(call, "not_connected", "channel \(n) is not open yet")
            return
        }
        guard let data = BleCore.bytes(hexValue, b64Value, text), !data.isEmpty else {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed and not empty")
            return
        }
        if data.count > BleCore.l2capSendMax {
            fail(call, "too_long", "\(data.count) bytes; at most \(BleCore.l2capSendMax) per call")
            return
        }
        if let err = port.l2capSend(n, data) {
            refused(call, err)
            return
        }
        ok(call, BleCore.obj(("channel", n), ("bytes", data.count)))
    }

    /// Bytes arrived on channel `n`: one l2cap_data record, batched like values.
    func l2capData(_ n: Int, _ hexValue: String) {
        guard let ch = channel(n), ch.state == "open" else {
            stale("l2cap_data \(n)")
            return
        }
        let rec = BleCore.obj(("channel", n), ("hex", hexValue))
        append("l2cap_data", rec)
        let view = BleCore.obj(("seq", nextSeq), ("t", journal[journal.count - 1].t))
        view.putAll(rec)
        pendingL2cap.append(view)
        scheduleFlush()
    }

    /// The platform closed channel `n` (the peer, or an error `code`).
    func l2capClosed(_ n: Int, _ code: String?) {
        guard let ch = channel(n) else {
            stale("l2cap_closed \(n)")
            return
        }
        channels.removeAll { $0 === ch }
        if ch.state == "opening" {
            fail(ch.call, "l2cap_failed", "the channel closed before it opened" + (code.map { ": " + $0 } ?? ""))
            return
        }
        ch.state = "closed"
        let rec = channelView(ch)
        rec["reason"] = code == nil ? "remote" : "error"
        if let c = code { rec["error"] = c }
        record("l2cap", rec)
        updateHold()
    }

    func l2capClose(_ call: Int, _ n: Int) {
        guard let ch = channel(n) else {
            fail(call, "not_found", "no channel \(n)")
            return
        }
        channels.removeAll { $0 === ch }
        port.l2capClose(n)
        if ch.state == "opening" {
            fail(ch.call, "l2cap_failed", "l2cap_close came before the channel opened")
        } else {
            ch.state = "closed"
            let rec = channelView(ch)
            rec["reason"] = "requested"
            record("l2cap", rec)
        }
        updateHold()
        ok(call, BleCore.obj(("channel", n), ("state", "closed")))
    }

    func l2capChannels(_ call: Int) {
        ok(call, BleCore.obj(("channels", channels.map { channelView($0) } as [Any]),
                             ("published", published.map { BleCore.obj(("psm", $0.psm), ("encrypted", $0.encrypted)) } as [Any])))
    }

    private var openChannels: Int { channels.filter { $0.state == "open" }.count }

    // MARK: extended advertising sets (Android)

    static let advSetLimit = "iOS advertises one legacy advertisement: CBPeripheralManager.startAdvertising "
        + "takes only a local name and service UUIDs; extended and periodic advertising sets are not in its API"

    final class AdvSet {
        let n: Int
        var call: Int
        var on = false

        init(_ n: Int, _ call: Int) {
            self.n = n
            self.call = call
        }
    }

    private var sets: [AdvSet] = []
    private var nextSet = 0

    /// The manufacturer and service data pairs of one AdvertiseData under `prefix`; a String is the error.
    private static func adData(_ raw: BleObj, _ prefix: String, _ withName: Bool) -> Any {
        let d = BleCore.obj()
        if withName {
            guard let uuids = uuidList(raw[prefix + "services"] as? String) else { return prefix + "services must be up to 20 UUIDs" }
            d["services"] = uuids as [Any]
            d["includeName"] = raw[prefix + "include_name"] as? Bool ?? false
        }
        let mid = raw[prefix + "manufacturer_id"] as? Int, mhex = raw[prefix + "manufacturer_hex"] as? String
        if (mid == nil) != (mhex == nil) || (mid.map { $0 < 0 || $0 > 0xFFFF } ?? false) || (mhex != nil && fromHex(mhex) == nil) {
            return prefix + "manufacturer_id (0 to 65535) and " + prefix + "manufacturer_hex go together, as an id and hex bytes"
        }
        d["manufacturerId"] = mid.map { $0 as Any } ?? NSNull()
        d["manufacturerHex"] = mhex.map { $0.lowercased() as Any } ?? NSNull()
        let su = raw[prefix + "service_data_uuid"] as? String, shex = raw[prefix + "service_data_hex"] as? String
        let sdUuid = su.flatMap { uuid($0) }
        if (su == nil) != (shex == nil) || (su != nil && sdUuid == nil) || (shex != nil && fromHex(shex) == nil) {
            return prefix + "service_data_uuid and " + prefix + "service_data_hex go together, as a UUID and hex bytes"
        }
        d["serviceDataUuid"] = sdUuid.map { $0 as Any } ?? NSNull()
        d["serviceDataHex"] = shex.map { $0.lowercased() as Any } ?? NSNull()
        return d
    }

    /// The advertise_set_start parameters, checked by the rules of Android's AdvertisingSetParameters and
    /// the Core specification; a String is the error, else the parameters for the radio.
    static func advertiseSetParams(_ raw: BleObj) -> Any {
        let legacy = raw["legacy"] as? Bool ?? false
        let connectable = raw["connectable"] as? Bool ?? false
        let scannable = raw["scannable"] as? Bool ?? false
        let anonymous = raw["anonymous"] as? Bool ?? false
        let includeTxPower = raw["include_tx_power"] as? Bool ?? false
        let primary = raw["primary_phy"] as? String ?? "1m", secondary = raw["secondary_phy"] as? String ?? "1m"
        if legacy {
            if anonymous { return "a legacy advertisement cannot be anonymous" }
            if connectable && !scannable { return "a legacy advertisement cannot be connectable and not scannable" }
            if includeTxPower { return "a legacy advertisement cannot carry the TX power in its header" }
            if primary != "1m" || secondary != "1m" { return "a legacy advertisement uses the 1M PHY" }
        } else {
            if connectable && scannable { return "an extended advertisement cannot be both connectable and scannable" }
            if anonymous && connectable { return "an extended advertisement cannot be both connectable and anonymous" }
        }
        let periodic = raw["periodic_interval_ms"] != nil
        if periodic && (legacy || connectable || scannable) {
            return "periodic advertising needs an extended set that is neither connectable nor scannable"
        }
        if !periodic && ["periodic_include_tx_power", "periodic_manufacturer_id", "periodic_manufacturer_hex",
                         "periodic_service_data_uuid", "periodic_service_data_hex"].contains(where: { raw[$0] != nil }) {
            return "periodic data needs periodic_interval_ms"
        }
        let response = ["response_services", "response_include_name", "response_manufacturer_id",
                        "response_manufacturer_hex"].contains(where: { raw[$0] != nil })
        if response && !scannable { return "a scan response needs a scannable set" }
        let data = adData(raw, "", true)
        guard let dobj = data as? BleObj else { return data }
        let p = obj(("legacy", legacy), ("connectable", connectable), ("scannable", scannable), ("anonymous", anonymous),
                    ("includeTxPower", includeTxPower), ("primaryPhy", primary), ("secondaryPhy", secondary))
        p["intervalMs"] = raw["interval_ms"] ?? NSNull()
        p["txPowerDbm"] = raw["tx_power_dbm"] ?? NSNull()
        p["data"] = dobj
        dobj["txPowerLevel"] = raw["tx_power_data"] as? Bool ?? false
        if response {
            let r = adData(raw, "response_", true)
            guard r is BleObj else { return r }
            p["response"] = r
        } else {
            p["response"] = NSNull()
        }
        if periodic {
            let d = adData(raw, "periodic_", false)
            guard d is BleObj else { return d }
            p["periodic"] = obj(("intervalMs", raw["periodic_interval_ms"]!),
                                ("includeTxPower", raw["periodic_include_tx_power"] as? Bool ?? false), ("data", d))
        } else {
            p["periodic"] = NSNull()
        }
        p["seconds"] = raw["seconds"] as? Int ?? 0
        p["maxEvents"] = raw["max_events"] as? Int ?? 0
        return p
    }

    func advertiseSetStart(_ call: Int, _ raw: BleObj) {
        if !android {
            fail(call, "platform_limit", BleCore.advSetLimit)
            return
        }
        let r = BleCore.advertiseSetParams(raw)
        guard let p = r as? BleObj else {
            fail(call, "bad_value", r as? String ?? "bad parameters")
            return
        }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        nextSet += 1
        let a = AdvSet(nextSet, call)
        if let err = port.advertiseSetStart(epoch, a.n, p) {
            refused(call, err)
            return
        }
        sets.append(a)
        port.timer("advertise_set", a.n, BleCore.opMs)
    }

    /// The platform started set `n` (code nil, with its TX power in dBm) or refused it.
    func advertiseSetStarted(_ e: Int, _ n: Int, _ txPower: Int, _ code: String?) {
        if !serverCurrent(e, "advertise_set_started") { return }
        guard let a = sets.first(where: { $0.n == n }), !a.on else {
            stale("advertise_set_started \(n)")
            return
        }
        let call = a.call
        a.call = -1
        if let code = code {
            sets.removeAll { $0 === a }
            fail(call, "advertise_failed", code)
            return
        }
        if call >= 0 && !port.isActive(call) {
            sets.removeAll { $0 === a }
            port.advertiseSetStop(n)
            fail(call, "timeout", "the set started after the route timed out")
            return
        }
        a.on = true
        record("advertising_set", BleCore.obj(("set", n), ("state", "started"), ("tx_power", txPower)))
        updateHold()
        ok(call, BleCore.obj(("set", n), ("tx_power", txPower)))
    }

    /// The platform ended set `n` by itself (its duration or event count ran out).
    func advertiseSetStopped(_ e: Int, _ n: Int) {
        if !serverCurrent(e, "advertise_set_stopped") { return }
        guard let a = sets.first(where: { $0.n == n }), a.on else {
            stale("advertise_set_stopped \(n)")
            return
        }
        sets.removeAll { $0 === a }
        record("advertising_set", BleCore.obj(("set", n), ("state", "stopped"), ("reason", "elapsed")))
        updateHold()
    }

    func advertiseSetStop(_ call: Int, _ n: Int) {
        guard let a = sets.first(where: { $0.n == n }) else {
            fail(call, "not_found", "no advertising set \(n)")
            return
        }
        sets.removeAll { $0 === a }
        port.advertiseSetStop(n)
        if !a.on {
            fail(a.call, "advertise_failed", "advertise_set_stop came before the platform started the set")
        } else {
            record("advertising_set", BleCore.obj(("set", n), ("state", "stopped"), ("reason", "requested")))
        }
        updateHold()
        ok(call, BleCore.obj(("set", n), ("state", "stopped")))
    }

    private var setsOn: Int { sets.filter { $0.on }.count }

    // MARK: Android restoration: wake scan and companion device presence

    static let wakeLimit = "iOS has no scan that outlives the app: a scan_start with services continues in the "
        + "background and is restored after a relaunch (CBCentralManager state restoration)"
    static let presenceLimit = "iOS has no API to observe a device's presence; a connect with no time limit "
        + "completes when the device comes in range, and state restoration relaunches the app for it"
    static let associateIOSAddress = "iOS gives an app no Bluetooth address (AccessorySetupKit answers a "
        + "Bluetooth identifier); filter by services and name"

    /// The running wake scan's filters (kept on disk by the port), or nil.
    private(set) var wake: BleObj?
    private var associateCall = -1
    private var nextAssociate = 0
    private var assocRequest = 0
    private var observing: [Int] = []

    /// Launch: the wake scan a previous process started is still the system's.
    func loadWake(_ filters: BleObj?) { wake = filters }

    var waking: Bool { wake != nil }

    /// Launch: the presence observations a previous process started stay the system's.
    func loadObserving(_ list: [Int]) { observing = list }

    var observingList: [Int] { observing }

    func wakeStart(_ call: Int, _ servicesCsv: String?, _ namesCsv: String?, _ manufacturerId: Int, _ manufacturerHex: String?,
                   _ mode: String?) {
        if !android {
            fail(call, "platform_limit", BleCore.wakeLimit)
            return
        }
        guard let services = BleCore.uuidList(servicesCsv) else {
            fail(call, "bad_value", "services must be up to 20 UUIDs")
            return
        }
        guard let names = BleCore.nameList(namesCsv) else {
            fail(call, "bad_value", "names must be up to 10 comma-separated names of 1 to 248 bytes")
            return
        }
        let prefix = manufacturerHex.flatMap { BleCore.fromHex($0) }
        if manufacturerId > 0xFFFF || (manufacturerHex != nil && (prefix == nil || manufacturerId < 0)) {
            fail(call, "bad_value", "manufacturer_id is 0 to 65535; manufacturer_hex is hex bytes and needs manufacturer_id")
            return
        }
        if services.isEmpty && names.isEmpty && manufacturerId < 0 {
            fail(call, "filter_required", "a wake scan needs a service, name or manufacturer filter")
            return
        }
        if !on {
            fail(call, "unavailable", "Bluetooth is \(adapterState)")
            return
        }
        if wake != nil {
            fail(call, "busy", "a wake scan is already running; wake_stop ends it")
            return
        }
        let f = BleCore.obj(("services", services as [Any]), ("names", names as [Any]))
        if manufacturerId >= 0 {
            f["manufacturer_id"] = manufacturerId
            f["manufacturer_hex"] = BleCore.hex(prefix ?? [])
        }
        let m = mode ?? "low_power"
        f["mode"] = m
        if let err = port.wakeStart(f, m) {
            refused(call, err)
            return
        }
        wake = f
        port.wakeSave(f)
        record("wake", BleCore.obj(("state", "started"), ("filters", f)))
        ok(call, BleCore.obj(("state", "started"), ("filters", f)))
    }

    func wakeStop(_ call: Int) {
        if !android {
            fail(call, "platform_limit", BleCore.wakeLimit)
            return
        }
        if wake == nil {
            ok(call, BleCore.obj(("state", "stopped"), ("stopped", false)))
            return
        }
        port.wakeStop()
        wake = nil
        port.wakeSave(nil)
        record("wake", BleCore.obj(("state", "stopped"), ("reason", "requested")))
        ok(call, BleCore.obj(("state", "stopped"), ("stopped", true)))
    }

    /// The system delivered the wake scan's PendingIntent: devices, or a SCAN_FAILED code that ends the scan.
    func wakeDelivered(_ devices: [BleObj], _ error: Int) {
        if wake == nil {
            stale("wake delivery")
            return
        }
        if error > 0 {
            port.wakeStop()
            wake = nil
            port.wakeSave(nil)
            record("wake", BleCore.obj(("state", "failed"), ("error", error)))
            return
        }
        let list = Array(devices.prefix(BleCore.devicesMax))
        if !list.isEmpty { record("wake", BleCore.obj(("state", "results"), ("devices", list as [Any]))) }
    }

    func associate(_ call: Int, _ raw: BleObj) {
        guard let services = BleCore.uuidList(raw["services"] as? String), services.count <= 1 else {
            fail(call, "bad_value", "services is one service UUID")
            return
        }
        // AccessorySetupKit filters by a service UUID or a company identifier (Apple, ASDiscoveryDescriptor:
        // "Provide at least one UUID or manufacturer ID to filter"), and its accessory has no address.
        if !android {
            if services.isEmpty {
                fail(call, "bad_value", "services is one service UUID: the iOS accessory picker filters by it")
                return
            }
            if let a = raw["address"], !(a is NSNull) {
                fail(call, "bad_value", BleCore.associateIOSAddress)
                return
            }
        }
        let address = raw["address"]
        if let a = address, !(a is NSNull) {
            guard let s = a as? String, s.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else {
                fail(call, "bad_value", "address is a Bluetooth address like 00:11:22:AA:BB:CC")
                return
            }
        }
        if associateCall >= 0 && port.isActive(associateCall) {
            fail(call, "busy", "the device chooser is already open")
            return
        }
        let p = BleCore.obj(("services", services as [Any]), ("name", BleCore.nul(raw["name"])), ("address", BleCore.nul(address)),
                            ("single", (raw["single"] as? Bool) != false))
        nextAssociate += 1
        let r = nextAssociate
        if let err = port.associate(r, p) {
            refused(call, err)
            return
        }
        associateCall = call
        assocRequest = r
    }

    func associated(_ r: Int, _ info: BleObj?, _ err: String?) {
        if r != assocRequest || associateCall < 0 {
            stale("associated \(r)")
            return
        }
        let call = associateCall
        associateCall = -1
        if let err = err {
            refused(call, err)
            return
        }
        ok(call, info ?? BleObj())
    }

    func associations(_ call: Int) {
        let r = port.associations()
        if let err = r as? String {
            refused(call, err)
            return
        }
        var list: [Any] = []
        for case let o as BleObj in (r as? [Any]) ?? [] {
            let m = BleObj()
            for k in o.keys { m[k] = o[k] }
            m["observing"] = (o["association"] as? Int).map { observing.contains($0) } ?? false
            list.append(m)
        }
        ok(call, BleCore.obj(("associations", list)))
    }

    func disassociate(_ call: Int, _ association: Int) {
        if association <= 0 {
            fail(call, "bad_value", "association is the id associate or associations gave")
            return
        }
        if let err = port.disassociate(association) {
            refused(call, err)
            return
        }
        observing.removeAll { $0 == association }
        ok(call, BleCore.obj(("association", association), ("removed", true)))
    }

    func presence(_ call: Int, _ association: Int, _ start: Bool) {
        if !android {
            fail(call, "platform_limit", BleCore.presenceLimit)
            return
        }
        if association <= 0 {
            fail(call, "bad_value", "association is the id associate or associations gave")
            return
        }
        if !start && !observing.contains(association) {
            ok(call, BleCore.obj(("association", association), ("observing", false), ("stopped", false)))
            return
        }
        if let err = port.presence(start, association) {
            refused(call, err)
            return
        }
        if start {
            if !observing.contains(association) { observing.append(association) }
        } else {
            observing.removeAll { $0 == association }
        }
        ok(call, start ? BleCore.obj(("association", association), ("observing", true))
            : BleCore.obj(("association", association), ("observing", false), ("stopped", true)))
    }

    /// The system reported a presence change of an associated device.
    func presenceEvent(_ association: Int, _ address: String?, _ event: String) {
        if association > 0 && !observing.contains(association) { observing.append(association) }
        record("presence", BleCore.obj(("association", association), ("address", BleCore.nul(address)), ("event", event)))
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
        for ch in channels {
            port.l2capClose(ch.n)
            if ch.state == "opening" {
                fail(ch.call, "unavailable", "Bluetooth is \(adapterState)")
            } else {
                ch.state = "closed"
                let rec = channelView(ch)
                rec["reason"] = "adapter"
                record("l2cap", rec)
            }
        }
        channels = []
        for p in publishing { fail(p.call, "unavailable", "Bluetooth is \(adapterState)") }
        publishing = []
        for p in published { port.l2capUnpublish(p.psm) }
        published = []
        for a in sets {
            if a.on {
                record("advertising_set", BleCore.obj(("set", a.n), ("state", "stopped"), ("reason", "adapter")))
            } else {
                fail(a.call, "unavailable", "Bluetooth is \(adapterState)")
            }
        }
        sets = []
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
    func holdCount() -> Int { links.count + centralList.count + (advertising ? 1 : 0) + setsOn + openChannels }

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
            for k in ["txPower", "includeTxPower"] where a[k] != nil { p[k] = a[k] }
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
        case "att":
            guard let i = requests.firstIndex(where: { $0.id == token }) else {
                stale("att timer \(token)")
                return
            }
            let q = requests.remove(at: i)
            _ = port.attRespond(q.epoch, token, "unlikely", q.offset, nil)
            record("att_request", BleCore.obj(("request", token), ("state", "expired"), ("status", "unlikely")))
        case "l2cap_publish":
            guard let i = publishing.firstIndex(where: { $0.t == token }) else {
                stale("l2cap_publish timer \(token)")
                return
            }
            let p = publishing.remove(at: i)
            fail(p.call, "l2cap_failed", "the platform did not answer the publish in \(BleCore.opMs / 1000) s")
        case "l2cap_open":
            guard let ch = channel(token), ch.state == "opening" else {
                stale("l2cap_open timer \(token)")
                return
            }
            channels.removeAll { $0 === ch }
            port.l2capClose(token)
            fail(ch.call, "timeout", "the channel did not open in time")
        case "advertise_set":
            guard let a = sets.first(where: { $0.n == token }), !a.on else {
                stale("advertise_set timer \(token)")
                return
            }
            sets.removeAll { $0 === a }
            port.advertiseSetStop(token)
            fail(a.call, "advertise_failed", "the platform did not answer the set start")

        default:
            stale("timer \(kind)")
        }
    }

    // MARK: journal

    /// `run`: nil or this run reads the live journal; the previous run's id reads the journal the
    /// previous app process left on disk.
    func events(_ call: Int, _ after: Int, _ max: Int, run asked: String? = nil) {
        if let r = asked, r != run {
            guard r == previousRun else {
                fail(call, "not_found", "no journal is kept for that run")
                return
            }
            var out: [Any] = []
            var next = after
            for rec in previousRecords where out.count < max {
                let seq = rec["seq"] as? Int ?? 0
                if seq <= after { continue }
                out.append(rec)
                next = seq
            }
            ok(call, BleCore.obj(("records", out), ("next", next), ("dropped", previousDropped), ("run", r)))
            return
        }
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
