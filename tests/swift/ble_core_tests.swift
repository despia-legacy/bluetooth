import Foundation

/// Runs the shared BLE core vector table (tests/vectors/ble_core.json) against
/// fixtures/ble/ios/app/BleCore.swift. The Java twin runs the same table in d-android
/// (scripts/tests/BleCoreTest.java). Each step names one core input; the fake port writes every port
/// call as one canonical line, and the lines must equal the step's "out" exactly. Prints one JSON
/// line per section or scenario: {"row", "name", "ok", "detail"}. No CoreBluetooth is involved.
enum BleCoreTests {
    // MARK: a small ordered JSON reader (JSONSerialization does not keep key order)

    struct Reader {
        let u: [UInt8]
        var i = 0

        init(_ s: String) { u = Array(s.utf8) }

        mutating func ws() {
            while i < u.count, u[i] == 32 || u[i] == 10 || u[i] == 13 || u[i] == 9 { i += 1 }
        }

        mutating func value() -> Any? {
            ws()
            let c = u[i]
            if c == 123 {
                i += 1
                let o = BleObj()
                ws()
                if u[i] == 125 { i += 1; return o }
                while true {
                    ws()
                    let k = value() as! String
                    ws()
                    i += 1
                    o[k] = value() ?? NSNull()
                    ws()
                    let e = u[i]
                    i += 1
                    if e == 125 { return o }
                }
            }
            if c == 91 {
                i += 1
                var l: [Any] = []
                ws()
                if u[i] == 93 { i += 1; return l }
                while true {
                    l.append(value() ?? NSNull())
                    ws()
                    let e = u[i]
                    i += 1
                    if e == 93 { return l }
                }
            }
            if c == 34 {
                i += 1
                var bytes: [UInt8] = []
                while u[i] != 34 {
                    let ch = u[i]
                    i += 1
                    if ch == 92 {
                        let e = u[i]
                        i += 1
                        if e == 117 {
                            let code = UInt32(String(decoding: u[i..<i + 4], as: UTF8.self), radix: 16)!
                            i += 4
                            bytes.append(contentsOf: Array(String(UnicodeScalar(code)!).utf8))
                        } else {
                            bytes.append(e == 110 ? 10 : e == 116 ? 9 : e)
                        }
                    } else {
                        bytes.append(ch)
                    }
                }
                i += 1
                return String(decoding: bytes, as: UTF8.self)
            }
            if u[i...].starts(with: Array("true".utf8)) { i += 4; return true }
            if u[i...].starts(with: Array("false".utf8)) { i += 5; return false }
            if u[i...].starts(with: Array("null".utf8)) { i += 4; return nil }
            var j = i
            while j < u.count, (u[j] >= 48 && u[j] <= 57) || u[j] == 45 { j += 1 }
            let n = Int(String(decoding: u[i..<j], as: UTF8.self))!
            i = j
            return n
        }
    }

    // MARK: the fake port

    final class Fake: BlePort {
        var out: [String] = []
        var refuse: [String: String] = [:]
        var expired: Set<Int> = []
        var closeNow = false
        var clock = 0

        private func take(_ kind: String) -> String? { refuse.removeValue(forKey: kind) }

        func scanStart(_ scan: Int, _ services: [String], _ duplicates: Bool, _ mode: String, _ options: BleObj) -> String? {
            out.append("scan_start \(scan) \(services.isEmpty ? "-" : services.joined(separator: ",")) \(duplicates) \(mode)"
                       + (options.keys.isEmpty ? "" : " " + BleCore.json(options)))
            return take("scan_start")
        }

        func scanStop(_ scan: Int) { out.append("scan_stop \(scan)") }

        func connect(_ id: String, _ gen: Int, _ auto: Bool, _ background: Bool) -> String? {
            out.append("connect \(id) \(gen) \(auto) \(background)")
            return take("connect")
        }

        func close(_ id: String, _ gen: Int) -> Bool {
            out.append("close \(id) \(gen)")
            return closeNow
        }

        func release(_ id: String, _ gen: Int) { out.append("release \(id) \(gen)") }

        func op(_ id: String, _ gen: Int, _ op: Int, _ kind: String, _ key: String?, _ descriptor: String?,
                _ data: [UInt8]?, _ arg: Int) -> String? {
            out.append("op \(id) \(gen) \(op) \(kind) \(key ?? "-") \(descriptor ?? "-") \(data.map { BleCore.hex($0) } ?? "-") \(arg)")
            return take("op")
        }

        func writable(_ id: String, _ gen: Int, _ withResponse: Bool) -> String? {
            out.append("writable \(id) \(gen) \(withResponse)")
            return take("writable")
        }

        func timer(_ kind: String, _ token: Int, _ ms: Int) { out.append("timer \(kind) \(token) \(ms)") }

        var messages: [Int: String] = [:]

        func reply(_ call: Int, _ ok: Bool, _ code: String?, _ message: String?, _ data: BleObj?) {
            out.append(ok ? "reply \(call) ok \(BleCore.json(data))" : "reply \(call) error \(code!)")
            if !ok { messages[call] = message ?? "" }
        }

        func emit(_ event: String, _ data: BleObj) { out.append("emit \(event) \(BleCore.json(data))") }

        func isActive(_ call: Int) -> Bool { !expired.contains(call) }

        func now() -> Int { clock }

        func stale(_ what: String) { out.append("stale \(what)") }

        /// What notify answers when no refusal is scripted: nil (handed over now) or "pending".
        var notifyMode: String?

        func serviceAdd(_ epoch: Int, _ uuid: String, _ primary: Bool, _ chars: [BleObj]) -> String? {
            out.append("service_add \(epoch) \(uuid) \(primary) \(BleCore.json(chars as [Any]))")
            return take("service_add")
        }

        func serviceRemove(_ uuid: String) { out.append("service_remove \(uuid)") }

        func advertiseStart(_ epoch: Int, _ adv: Int, _ params: BleObj) -> String? {
            out.append("advertise_start \(epoch) \(adv) \(BleCore.json(params))")
            return take("advertise_start")
        }

        func advertiseStop(_ adv: Int) { out.append("advertise_stop \(adv)") }

        func notify(_ epoch: Int, _ packet: Int, _ central: String, _ key: String, _ data: [UInt8], _ indicate: Bool) -> String? {
            out.append("notify \(epoch) \(packet) \(central) \(key) \(BleCore.hex(data)) \(indicate)")
            guard let r = take("notify") else { return notifyMode }
            return r == "-" ? nil : r
        }

        func centralDrop(_ central: String) { out.append("central_drop \(central)") }

        func keepAlive(_ start: Bool, _ hold: Int) -> String? {
            out.append("keep_alive \(start) \(hold)")
            return start ? take("keep_alive") : nil
        }

        func persist(_ snapshot: BleObj?) { out.append("persist \(BleCore.json(snapshot))") }

        func attRespond(_ epoch: Int, _ request: Int, _ status: String, _ offset: Int, _ data: [UInt8]?) -> String? {
            out.append("att_respond \(epoch) \(request) \(status) \(offset) \(data.map { BleCore.hex($0) } ?? "-")")
            return take("att_respond")
        }

        func l2capPublish(_ epoch: Int, _ t: Int, _ encrypted: Bool) -> String? {
            out.append("l2cap_publish \(epoch) \(t) \(encrypted)")
            return take("l2cap_publish")
        }

        func l2capUnpublish(_ psm: Int) { out.append("l2cap_unpublish \(psm)") }

        func l2capOpen(_ epoch: Int, _ channel: Int, _ id: String, _ psm: Int, _ encrypted: Bool) -> String? {
            out.append("l2cap_open \(epoch) \(channel) \(id) \(psm) \(encrypted)")
            return take("l2cap_open")
        }

        func l2capSend(_ channel: Int, _ data: [UInt8]) -> String? {
            out.append("l2cap_send \(channel) \(BleCore.hex(data))")
            return take("l2cap_send")
        }

        func l2capClose(_ channel: Int) { out.append("l2cap_close \(channel)") }

        func advertiseSetStart(_ epoch: Int, _ set: Int, _ params: BleObj) -> String? {
            out.append("advertise_set_start \(epoch) \(set) \(BleCore.json(params))")
            return take("advertise_set_start")
        }

        func advertiseSetStop(_ set: Int) { out.append("advertise_set_stop \(set)") }
    }

    // MARK: step driver

    static func str(_ st: BleObj, _ k: String) -> String? { st[k] as? String }
    static func num(_ st: BleObj, _ k: String, _ d: Int) -> Int { (st[k] as? Int) ?? d }
    static func flag(_ st: BleObj, _ k: String, _ d: Bool) -> Bool { (st[k] as? Bool) ?? d }

    static func step(_ core: BleCore, _ port: Fake, _ st: BleObj) {
        let d = str(st, "do")!
        let call = num(st, "call", -1)
        switch d {
        case "port":
            if let r = st["refuse"] as? BleObj { for k in r.keys { port.refuse[k] = r[k] as? String } }
            if let c = st["close_now"] as? Bool { port.closeNow = c }
            if let n = st["now"] as? Int { port.clock = n }
            if st["notify_mode"] != nil { port.notifyMode = st["notify_mode"] as? String }
        case "expire": port.expired.insert(call)
        case "adapter": core.adapter(str(st, "state")!)
        case "state": port.out.append("state \(BleCore.json(core.stateFields()))")
        case "stale_count": port.out.append("stale_count \(core.staleDrops)")
        case "scan_start":
            core.scanStart(call, str(st, "services"), num(st, "seconds", 0), flag(st, "duplicates", false),
                           str(st, "mode") ?? "balanced", flag(st, "background", false),
                           names: str(st, "names"), manufacturerId: num(st, "manufacturer_id", -1),
                           manufacturerHex: str(st, "manufacturer_hex"), options: (st["options"] as? BleObj)?.copy() ?? BleObj())
        case "scan_stop": core.scanStop(call)
        case "device": core.device(num(st, "scan", 0), str(st, "id")!, st["adv"] as! BleObj)
        case "scan_failed": core.scanFailed(num(st, "scan", 0), "failed")
        case "background": core.background(flag(st, "value", true))
        case "devices": core.devices(call)
        case "connect": core.connect(call, str(st, "id"), flag(st, "auto", false), num(st, "seconds", 10))
        case "connected": core.connected(str(st, "id")!, num(st, "gen", 0), num(st, "mtu", 23))
        case "disconnected": core.disconnected(str(st, "id")!, num(st, "gen", 0), str(st, "reason") ?? "remote",
                                               error: (st["error"] as? BleObj).map {
                                                   // The radio's form: the core's platformError, so the name table is exercised.
                                                   BleCore.platformError($0["domain"] as! String, $0["code"] as! Int, $0["message"] as! String)
                                               })
        case "message": port.out.append("message \(call) \(port.messages[call] ?? "-")")
        case "disconnect": core.disconnect(call, str(st, "id"))
        case "links": core.links(call)
        case "discover": core.discover(call, str(st, "id"))
        case "read":
            core.read(call, str(st, "id"), str(st, "service"), num(st, "service_n", 0), str(st, "char"), num(st, "char_n", 0),
                      str(st, "descriptor"))
        case "write":
            core.write(call, str(st, "id"), str(st, "service"), num(st, "service_n", 0), str(st, "char"), num(st, "char_n", 0),
                       str(st, "descriptor"), str(st, "hex"), str(st, "b64"), flag(st, "response", true), text: str(st, "text"))
        case "raw": core.raw(call, str(st, "id"), str(st, "hex"), str(st, "b64"), str(st, "text"), flag(st, "response", true))
        case "priority": core.priority(call, str(st, "id"), str(st, "level")!)
        case "phy": core.phy(call, str(st, "id"), str(st, "tx"), str(st, "rx"), str(st, "coded") ?? "none")
        case "phy_changed": core.phyChanged(str(st, "id")!, num(st, "gen", 0), str(st, "tx")!, str(st, "rx")!, str(st, "code"))
        case "external": core.external(str(st, "event")!, st["data"] as! BleObj)
        case "journal_persist":
            if let j = core.journalToPersist() {
                port.out.append("journal \(j.rewrite) \(BleCore.json(j.records as [Any]))")
            } else {
                port.out.append("journal -")
            }
        case "load_previous":
            core.loadPrevious(str(st, "run")!, (st["records"] as! [Any]).map { $0 as! BleObj })
        case "subscribe", "unsubscribe":
            core.subscribe(call, str(st, "id"), str(st, "service"), num(st, "service_n", 0), str(st, "char"), num(st, "char_n", 0),
                           d == "subscribe")
        case "rssi": core.rssi(call, str(st, "id"))
        case "mtu": core.mtu(call, str(st, "id"), num(st, "size", 517))
        case "op_done":
            core.opDone(str(st, "id")!, num(st, "gen", 0), num(st, "op", 0), str(st, "code"), str(st, "message"), st["data"] as? BleObj)
        case "mtu_changed": core.mtuChanged(str(st, "id")!, num(st, "gen", 0), num(st, "mtu", 23), flag(st, "success", true))
        case "value":
            core.value(str(st, "id")!, num(st, "gen", 0), str(st, "key")!, str(st, "hex")!, flag(st, "maybe_read", false))
        case "gatt_changed": core.gattChanged(str(st, "id")!, num(st, "gen", 0))
        case "timer": core.timer(str(st, "kind")!, num(st, "token", 0))
        case "events": core.events(call, num(st, "after", 0), num(st, "max", 200), run: str(st, "run"))
        case "restored":
            let subs = (st["subscribed"] as? [Any])?.compactMap { $0 as? String } ?? []
            port.out.append("gen \(core.restored(str(st, "id")!, connected: flag(st, "connected", true), subscribed: subs, pending: flag(st, "pending", false)))")
        case "restored_event": core.restoredEvent(st["data"] as! BleObj)
        case "service_add": core.serviceAdd(call, str(st, "uuid"), flag(st, "primary", true), str(st, "chars"))
        case "service_added": core.serviceAdded(num(st, "epoch", 1), str(st, "uuid")!, str(st, "code"))
        case "service_remove": core.serviceRemove(call, str(st, "uuid"))
        case "services": core.servicesList(call)
        case "value_set":
            core.valueSet(call, str(st, "service"), str(st, "char"), num(st, "char_n", 0), str(st, "hex"), str(st, "b64"),
                          text: str(st, "text"))
        case "notify":
            core.notify(call, str(st, "service"), str(st, "char"), num(st, "char_n", 0), str(st, "hex"), str(st, "b64"),
                        str(st, "central"), text: str(st, "text"))
        case "notify_sent": core.notifySent(num(st, "epoch", 1), num(st, "packet", 0), str(st, "code"))
        case "notify_ready": core.notifyReady(num(st, "epoch", 1))
        case "central_connected": core.centralConnected(num(st, "epoch", 1), str(st, "central")!, num(st, "mtu", 23))
        case "central_mtu": core.centralMtu(num(st, "epoch", 1), str(st, "central")!, num(st, "mtu", 23))
        case "central_disconnected": core.centralDisconnected(num(st, "epoch", 1), str(st, "central")!)
        case "subscription":
            port.out.append("status " + core.subscription(num(st, "epoch", 1), str(st, "central")!, num(st, "mtu", 23),
                                                          str(st, "key")!, str(st, "mode")))
        case "cccd": port.out.append("cccd " + core.cccd(str(st, "central")!, str(st, "key")!))
        case "read_request":
            port.out.append("answer " + BleCore.json(core.readRequest(num(st, "epoch", 1), str(st, "central")!, num(st, "mtu", 23),
                                                                       str(st, "key")!, num(st, "offset", 0))))
        case "write_request":
            let reqs = (st["requests"] as! [Any]).map { $0 as! BleObj }
            port.out.append("status " + core.writeRequests(num(st, "epoch", 1), str(st, "central")!, num(st, "mtu", 23), reqs,
                                                           flag(st, "prepare", false)))
        case "execute_write":
            port.out.append("status " + core.executeWrite(num(st, "epoch", 1), str(st, "central")!, flag(st, "execute", true)))
        case "centrals": core.centrals(call)
        case "central_drop": core.centralDrop(call, str(st, "central"))
        case "advertise_start":
            core.advertiseStart(call, str(st, "services"), str(st, "name"), num(st, "manufacturer_id", -1), str(st, "manufacturer_hex"),
                                str(st, "service_data_uuid"), str(st, "service_data_hex"), flag(st, "connectable", true),
                                str(st, "mode") ?? "balanced", num(st, "seconds", 0),
                                txPower: str(st, "tx_power"), includeTxPower: st["include_tx_power"] as? Bool)
        case "advertise_started": core.advertiseStarted(num(st, "epoch", 1), num(st, "adv", 0), str(st, "code"))
        case "advertise_stop": core.advertiseStop(call)
        case "keep_alive": core.keepAlive(call, flag(st, "enabled", true), flag(st, "background_modes", true))
        case "hold_current": port.out.append("hold_current \(core.holdCurrent(num(st, "hold", 0)))")
        case "hold_count": port.out.append("hold_count \(core.holdCount())")
        case "respond":
            core.respond(call, num(st, "request", 0), str(st, "status"), str(st, "hex"), str(st, "b64"), str(st, "text"),
                         num(st, "offset", -1))
        case "l2cap_publish": core.l2capPublish(call, flag(st, "encrypted", false))
        case "l2cap_published": core.l2capPublished(num(st, "epoch", 1), num(st, "t", 1), num(st, "psm", 0), str(st, "code"))
        case "l2cap_unpublish": core.l2capUnpublish(call, num(st, "psm", 0))
        case "l2cap_incoming":
            port.out.append("channel \(core.l2capIncoming(num(st, "epoch", 1), num(st, "psm", 0), str(st, "peer")!))")
        case "l2cap_open":
            core.l2capOpen(call, str(st, "id"), num(st, "psm", 0), flag(st, "encrypted", false), num(st, "seconds", 0))
        case "l2cap_opened": core.l2capOpened(num(st, "epoch", 1), num(st, "channel", 0), str(st, "code"))
        case "l2cap_send": core.l2capSend(call, num(st, "channel", 0), str(st, "hex"), str(st, "b64"), str(st, "text"))
        case "l2cap_data": core.l2capData(num(st, "channel", 0), str(st, "hex")!)
        case "l2cap_closed": core.l2capClosed(num(st, "channel", 0), str(st, "code"))
        case "l2cap_close": core.l2capClose(call, num(st, "channel", 0))
        case "l2cap_channels": core.l2capChannels(call)
        case "advertise_set_start": core.advertiseSetStart(call, st["params"] as? BleObj ?? BleObj())
        case "advertise_set_started":
            core.advertiseSetStarted(num(st, "epoch", 1), num(st, "set", 0), num(st, "tx_power", 0), str(st, "code"))
        case "advertise_set_stopped": core.advertiseSetStopped(num(st, "epoch", 1), num(st, "set", 0))
        case "advertise_set_stop": core.advertiseSetStop(call, num(st, "set", 0))
        default:
            if !extra(core, port, st, d) { preconditionFailure("unknown step \(d)") }
        }
    }

    /// Steps added by later sections; false marks an unknown step.
    static var extra: (BleCore, Fake, BleObj, String) -> Bool = { _, _, _, _ in false }

    static func report(_ row: String, _ name: String, _ ok: Bool, _ detail: String) {
        print(BleCore.json(BleCore.obj(("row", row), ("name", name), ("ok", ok), ("detail", detail))))
    }

    static func scenario(_ row: String, _ sc: BleObj) {
        let name = sc["name"] as! String
        let port = Fake()
        let core = BleCore(port: port, platform: sc["platform"] as! String, run: "r1")
        let steps = sc["steps"] as! [Any]
        for (k, s) in steps.enumerated() {
            let st = s as! BleObj
            port.out = []
            let repeatCount = num(st, "repeat", 1)
            for r in 0..<repeatCount {
                let one = st.copy()
                if let c = st["call"] as? Int { one["call"] = c + r }
                step(core, port, one)
            }
            let want = (st["out"] as? [Any] ?? []).map { $0 as! String }
            if port.out != want {
                report(row, name, false, "step \(k) (\(str(st, "do")!)): got \(port.out) want \(want)")
                return
            }
        }
        report(row, name, true, "")
    }

    static func codec(_ fn: String, _ input: [Any]) -> Any? {
        let a = input.map { $0 is NSNull ? nil : $0 as? String }
        switch fn {
        case "hex": return BleCore.hex(BleCore.fromHex(a[0])!)
        case "fromHex": return BleCore.fromHex(a[0]).map { BleCore.hex($0) }
        case "fromB64": return BleCore.fromB64(a[0]).map { BleCore.hex($0) }
        case "uuid": return BleCore.uuid(a[0])
        case "uuidList": return BleCore.uuidList(a[0]).map { $0 as [Any] }
        case "isId": return BleCore.isId(a[0], a[1]!)
        case "bytes": return BleCore.bytes(a[0], a[1], a.count > 2 ? a[2] : nil).map { BleCore.hex($0) }
        case "nameList": return BleCore.nameList(a[0]).map { $0 as [Any] }
        case "phyList": return BleCore.phyList(a[0]).map { $0 as [Any] }
        case "chars": return BleCore.parseChars(a[0]).map { $0 as [Any] }
        default: return codecExtra(fn, a)
        }
    }

    static var codecExtra: (String, [String?]) -> Any? = { fn, _ in preconditionFailure("unknown codec function \(fn)") }

    static func run(_ path: String) {
        let text = try! String(contentsOfFile: path, encoding: .utf8)
        var reader = Reader(text)
        let doc = reader.value() as! BleObj
        let sections = doc["sections"] as! BleObj
        for key in sections.keys {
            let s = sections[key] as! BleObj
            let row = s["row"] as! String
            if let cases = s["cases"] as? [Any] {
                var bad: [String] = []
                for c in cases {
                    let r = c as! BleObj
                    let got = BleCore.json(codec(r["fn"] as! String, r["in"] as! [Any]))
                    let want = BleCore.json(r["out"])
                    if got != want { bad.append("\(r["fn"]!)\(BleCore.json(r["in"])): got \(got) want \(want)") }
                }
                report(row, key, bad.isEmpty, bad.joined(separator: "; "))
            }
            if let scs = s["scenarios"] as? [Any] {
                for sc in scs { scenario(row, sc as! BleObj) }
            }
        }
        serverFile()
    }

    /// BL-P12, iOS only (Android has no state restoration, so the shared table has no rows for it):
    /// the launch decision for ble-server.json, a snapshot round trip through the file's JSON form, and
    /// a restored service whose file was unreadable.
    static func serverFile() {
        var bad: [String] = []
        for (file, restored, want) in [("absent", false, "none"), ("absent", true, "none"), ("unreadable", false, "move_aside"),
                                       ("unreadable", true, "move_aside"), ("readable", true, "keep"),
                                       ("readable", false, "delete")] {
            let got = BleCore.serverFileAction(file, restored: restored)
            if got != want { bad.append("\(file) restored=\(restored): got \(got) want \(want)") }
        }
        let svc = "0000180d-0000-1000-8000-00805f9b34fb", chr = "00002a37-0000-1000-8000-00805f9b34fb"
        let key = BleCore.key(svc, 0, chr, 0)
        let pa = Fake(), a = BleCore(port: pa, platform: "ios", run: "r1")
        a.adapter("on")
        a.serviceAdd(1, "180d", true, "2a37~rwn~0102,2a38~c")
        a.serviceAdded(1, svc, nil)
        a.valueSet(2, "180d", "2a37", 0, "0a0b0c", nil)
        pa.clock = 1000
        a.advertiseStart(3, "180d", "Despia", -1, nil, nil, nil, true, "balanced", 60)
        a.advertiseStarted(1, 1, nil)
        let snap = BleCore.json(a.serverSnapshot())
        let dict = try? JSONSerialization.jsonObject(with: Data(snap.utf8)) as? [String: Any]
        if dict == nil { bad.append("the snapshot is not JSON: \(snap)") }
        let pb = Fake(), b = BleCore(port: pb, platform: "ios", run: "r2")
        pb.clock = 2000
        b.serverRestored(dict, restoredServices: [svc], wasAdvertising: true)
        if BleCore.json(b.serverSnapshot()) != snap { bad.append("round trip: got \(BleCore.json(b.serverSnapshot())) want \(snap)") }
        pb.out = []
        b.adapter("on")
        if pb.out.contains(where: { $0.hasPrefix("service_add") || $0.hasPrefix("advertise_start") }) {
            bad.append("restored services or advertising were added again: \(pb.out)")
        }
        let read = BleCore.json(b.readRequest(1, "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", 185, key, 1))
        if read != "{\"status\":\"ok\",\"hex\":\"0b0c\"}" { bad.append("restored read: \(read)") }
        if !b.advertising { bad.append("restored advertising is not reported") }
        let pc = Fake(), c = BleCore(port: pc, platform: "ios", run: "r3")
        c.serverRestored(nil, restoredServices: ["180D"], wasAdvertising: true)
        let rec = pc.out.first { $0.hasPrefix("emit restored ") } ?? ""
        if rec != "emit restored {\"services\":[\"\(svc)\"],\"advertising\":false,\"lost\":[\"\(svc)\"]}" {
            bad.append("lost restore record: \(rec)")
        }
        c.adapter("on")
        let lost = BleCore.json(c.readRequest(1, "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", 185, key, 0))
        if lost != "{\"status\":\"unlikely\"}" { bad.append("read of a lost service: \(lost)") }
        report("BL-P12", "server_file_launch_round_trip_and_lost_state", bad.isEmpty, bad.joined(separator: "; "))
    }
}
