import Foundation
import UIKit

/// The `server` parameter of `connect` and `subscribe`: every link change of that device is POSTed to
/// the URL as `ble_state`, every notification of that characteristic as `ble_data`, in every app
/// state, in the bodies the retired core used. Posts wait in a queue kept in the data directory (the
/// newest 500, oldest dropped) and are sent one at a time; a failed post is retried after 30 s and at
/// the next route call after a launch, so a dead network loses nothing (the retired iOS core had no
/// retry).
///
/// A URL reaches this type only through a route call the bridge accepted against the build's
/// approved `https_url` hosts, and the approved manifest is fixed for the build, so a stored URL stays
/// approved for as long as it is kept.
@MainActor
final class BleServerMirror {
    static let queueMax = 500
    static let retrySeconds: UInt64 = 30
    static let timeoutSeconds: TimeInterval = 15

    private let file: URL
    private let log: (String) -> Void
    private var stateUrl: [String: String] = [:]
    private var dataUrl: [String: String] = [:]
    private var queue: [[String: Any]] = []
    private var sending = false
    private var retryPending = false
    private(set) var dropped = 0
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = BleServerMirror.timeoutSeconds
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    init(dataDirectory: URL, log: @escaping (String) -> Void) {
        let dir = dataDirectory.appendingPathComponent("ble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("server.json")
        self.log = log
        load()
    }

    func watchState(_ id: String, _ url: String) {
        stateUrl[id] = url
        save()
    }

    func watchData(_ id: String, _ key: String, _ url: String) {
        dataUrl[id + "|" + key] = url
        save()
    }

    func unwatchData(_ id: String, _ key: String) {
        if dataUrl.removeValue(forKey: id + "|" + key) != nil { save() }
    }

    /// Called for every event the core emits.
    func onEvent(_ event: String, _ data: BleObj, background: Bool) {
        let now = Date().timeIntervalSince1970
        if event == "link", let id = data["id"] as? String, let url = stateUrl[id] {
            var body: [String: Any] = ["event": "ble_state", "deviceId": id, "state": data["state"] ?? "unknown",
                                       "timestamp": now, "background": background, "battery": battery()]
            if let e = data["error"] as? BleObj, let m = e["message"] { body["error"] = m }
            else if (data["state"] as? String) != "connected", let r = data["reason"] { body["reason"] = r }
            enqueue(url, body)
            // The page ended the link itself: its last state is posted, then the device is no longer watched.
            if (data["state"] as? String) == "disconnected" && (data["reason"] as? String) == "requested" {
                stateUrl.removeValue(forKey: id)
                save()
            }
        } else if event == "value", let id = data["id"] as? String, let su = data["service"] as? String,
                  let cu = data["char"] as? String, let hex = data["hex"] as? String {
            let key = BleCore.key(su, data["service_n"] as? Int ?? 0, cu, data["char_n"] as? Int ?? 0)
            guard let url = dataUrl[id + "|" + key] else { return }
            let bytes = BleCore.fromHex(hex) ?? []
            enqueue(url, ["event": "ble_data", "deviceId": id, "service": su, "characteristic": cu,
                          "value": Data(bytes).base64EncodedString(), "valueHex": hex.uppercased(),
                          "timestamp": now, "background": background, "battery": battery()])
        }
    }

    /// 0 to 100, or -1 when the platform does not report it (UIDevice.batteryLevel is -1 then).
    private func battery() -> Int {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let l = UIDevice.current.batteryLevel
        return l < 0 ? -1 : Int((l * 100).rounded())
    }

    private func enqueue(_ url: String, _ body: [String: Any]) {
        queue.append(["url": url, "body": body])
        while queue.count > BleServerMirror.queueMax {
            queue.removeFirst()
            dropped += 1
        }
        save()
        pump()
    }

    /// Sends the oldest post; on success the next, on failure a retry in 30 s.
    func pump() {
        guard !sending, let first = queue.first, let s = first["url"] as? String, let url = URL(string: s),
              let body = first["body"], let json = try? JSONSerialization.data(withJSONObject: body) else {
            if !sending && !queue.isEmpty {
                log("server mirror: an unreadable post was dropped")
                queue.removeFirst()
                save()
                pump()
            }
            return
        }
        sending = true
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let token = first["body"] as? NSDictionary
        let task = session.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<300).contains(code)
            Task { @MainActor [weak self] in self?.sent(ok, token) }
        }
        task.resume()
    }

    private func sent(_ ok: Bool, _ token: NSDictionary?) {
        sending = false
        if ok {
            if let t = token, let head = queue.first?["body"] as? NSDictionary, head == t { queue.removeFirst() }
            save()
            pump()
        } else if !retryPending {
            retryPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: BleServerMirror.retrySeconds * 1_000_000_000)
                self?.retryPending = false
                self?.pump()
            }
        }
    }

    private func save() {
        let o: [String: Any] = ["state": stateUrl, "data": dataUrl, "queue": queue]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        do {
            try d.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log("server mirror: save \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let d = try? Data(contentsOf: file) else { return }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            log("server mirror: the queue file is unreadable and was reset")
            return
        }
        stateUrl = o["state"] as? [String: String] ?? [:]
        dataUrl = o["data"] as? [String: String] ?? [:]
        queue = o["queue"] as? [[String: Any]] ?? []
    }

    /// What the `state` route reports.
    func status() -> BleObj {
        BleCore.obj(("servers", stateUrl.count + dataUrl.count), ("pending", queue.count), ("dropped", dropped))
    }
}
