#!/usr/bin/env python3
"""Runs the shared BLE core vector table (tests/vectors/ble_core.json) against both cores.

  python3 -I tests/run.py jvm     # android/ble/.../BleCore.java with javac + java (JDK 17+)
  python3 -I tests/run.py swift   # ios/app/BleCore.swift with swiftc (macOS)

Each mutation below must turn its named scenario red (a negative control): a mutation that
passes means the vectors no longer guard that rule. Exit 0 only when every row passes and every
mutation is caught. Offline: the cores import nothing from Android or CoreBluetooth.
"""
import json, os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VECTORS = os.path.join(ROOT, "tests", "vectors", "ble_core.json")
JAVA_CORE = os.path.join(ROOT, "android", "ble", "src", "main", "java", "despia", "ext", "ble", "BleCore.java")
JAVA_TEST = os.path.join(ROOT, "tests", "jvm", "BleCoreTest.java")
SWIFT_CORE = os.path.join(ROOT, "ios", "app", "BleCore.swift")
SWIFT_TEST = os.path.join(ROOT, "tests", "swift", "ble_core_tests.swift")

JAVA_MUTATIONS = [
    ("M1", "return l != null && l.gen == gen && !l.closed;", "return l != null && !l.closed;", "link_stale_callbacks_change_nothing"),
    ("M3", 'if (o != null && "mtu".equals(o.kind)) {', "if (o != null) {", "queue_fifo_refusal_inactive_and_unsolicited_mtu"),
    ("M4", "if (!o.internal && !port.isActive(o.call)) {", "if (false) {", "queue_fifo_refusal_inactive_and_unsolicited_mtu"),
    ("M6", "if (closing.containsKey(id)) {", "if (false) {", "link_connect_waits_for_the_confirmed_close_then_times_out"),
    ("M11", "if (data.length > WRITE_MAX) {", "if (false) {", "writes_limits_chunks_and_loss"),
    ("P11", "if (!neverForLocation) runtime.add(", "if (true) runtime.add(", "permissions_by_api_level_and_role"),
    ("M5", "if (e == epoch && on()) return true;", "if (on()) return true;", "epoch_server_down_and_up_drops_old_callbacks"),
    ("K1", "return holdActive && g == holdGen;", "return holdActive;", "keepalive_hold_generation_android"),
    ("S1", "if (data.length > room) {", "if (false) {", "server_subscriptions_and_notify_queue"),
    ("S2", "if (advCall >= 0 && !port.isActive(advCall)) {", "if (false) {", "advertise_ios_applied_failure_late_answer_and_stop"),
    ("E1", 'if (error != null) rec.put("error", error);', "if (false) {}", "link_failed_connect_carries_the_gatt_status"),
    ("E2", '"the connection ended: " + reason + errorText(error)', '"the connection ended: " + reason', "link_failed_connect_carries_the_gatt_status"),
    ("A1", 'if ("connecting".equals(pending.state) && pending.connectCall < 0 && !pending.closed) {', "if (false) {", "reconnect_pending_attempt_is_adopted_by_a_page_connect"),
    ("T1", "            boundPending(l, CONNECT_DEFAULT_MS);", "", "restore_pending_connect_never_adopted_ends_at_the_connect_timeout"),
    ("N1", "return n == null ? fallback : n[1];", "return fallback;", "restore_pending_connect_joined_resolves_with_the_platform_error"),
]
SWIFT_MUTATIONS = [
    ("M1", "return l != nil && l!.gen == gen && !l!.closed", "return l != nil && !l!.closed", "link_stale_callbacks_change_nothing"),
    ("M3", 'if let o = l.inFlight, o.kind == "mtu" {', "if let o = l.inFlight {", "queue_fifo_refusal_inactive_and_unsolicited_mtu"),
    ("M4", "if !o.internal && !port.isActive(o.call) {", "if false {", "queue_fifo_refusal_inactive_and_unsolicited_mtu"),
    ("M6", "if closing[id] != nil {", "if false {", "link_connect_waits_for_the_confirmed_close_then_times_out"),
    ("M11", "if data.count > BleCore.writeMax {", "if false {", "writes_limits_chunks_and_loss"),
    ("M5", "if e == epoch && on { return true }", "if on { return true }", "epoch_server_down_and_up_drops_old_callbacks"),
    ("K1", "func holdCurrent(_ g: Int) -> Bool { holdActive && g == holdGen }", "func holdCurrent(_ g: Int) -> Bool { holdActive }", "keepalive_hold_generation_android"),
    ("S1", "if data.count > room {", "if false {", "server_subscriptions_and_notify_queue"),
    ("S2", "if advCall >= 0 && !port.isActive(advCall) {", "if false {", "advertise_ios_applied_failure_late_answer_and_stop"),
    ("M12", '        return "delete"\n', '        return "keep"\n', "server_file_launch_round_trip_and_lost_state"),
    ("E1", 'if let e = error { rec["error"] = e }', "if false { _ = error }", "link_failed_connect_carries_the_platform_error"),
    ("E2", '"the connection ended: \\(reason)" + BleCore.errorText(error)', '"the connection ended: \\(reason)"', "link_failed_connect_carries_the_platform_error"),
    ("A1", 'if l.state == "connecting" && l.connectCall < 0 && !l.closed {', "if false {", "restore_pending_connect_is_adopted_by_a_page_connect"),
    ("T1", "            boundPending(l, BleCore.connectDefaultMs)\n", "", "restore_pending_connect_never_adopted_ends_at_the_connect_timeout"),
    ("N1", "        return n.1\n", "        return fallback\n", "restore_pending_connect_joined_resolves_with_the_platform_error"),
]
LIMIT = "iOS has no API to request a connection priority or interval; the system and the peripheral set it"
NEW_MUTATIONS = {  # rules added in this repo (section "finish"), guarded on both cores
    "jvm": [
        ("F1", "if (!SCAN_OPTION_KEYS.contains(k)) {", "if (false) {", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F2", "if (!(n instanceof String) || !scanNames.contains(n)) return false;", "", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F3", LIMIT + '");\n            return;', LIMIT + '");', "finish_priority_and_phy_ios_are_platform_limits"),
        ("F4", '"reason", l.background && !l.unbounded ? "auto" : "requested"', '"reason", l.background ? "auto" : "requested"', "finish_connect_unbounded_answers_at_once_and_waits"),
        ("F5", "if (!asked.equals(previousRun)) {", "if (true) {", "finish_journal_persists_and_serves_the_previous_run"),
    ],
    "swift": [
        ("F1", "for k in options.keys where !BleCore.scanOptionKeys.contains(k) {", "for k in options.keys where false {", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F2", 'guard let n = adv["name"] as? String, scanNames.contains(n) else { return false }', "_ = adv", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F3", LIMIT + '")\n            return\n', LIMIT + '")\n', "finish_priority_and_phy_ios_are_platform_limits"),
        ("F4", '("reason", l.background && !l.unbounded ? "auto" : "requested")', '("reason", l.background ? "auto" : "requested")', "finish_connect_unbounded_answers_at_once_and_waits"),
        ("F5", "guard r == previousRun else {", "guard false else {", "finish_journal_persists_and_serves_the_previous_run"),
    ],
}


def run_jvm(src, work, label):
    d = os.path.join(work, label); os.makedirs(d)
    core = os.path.join(d, "BleCore.java"); open(core, "w").write(src)
    subprocess.run(["javac", "-encoding", "UTF-8", "-nowarn", "-proc:none", "-d", d, core, JAVA_TEST], check=True,
                   stderr=subprocess.DEVNULL)
    p = subprocess.run(["java", "-cp", d, "nxtest.BleCoreTest", VECTORS], capture_output=True, text=True, timeout=180)
    rows = {}
    for line in p.stdout.splitlines():
        if line.startswith("PASS "):
            rows[line[5:].strip()] = (True, "")
        elif line.startswith("FAIL "):
            n, _, det = line[5:].partition(":")
            rows[n.strip()] = (False, det.strip())
    return rows, p.stdout + p.stderr


def run_swift(src, work, label):
    d = os.path.join(work, label); os.makedirs(d)
    core = os.path.join(d, "BleCore.swift"); open(core, "w").write(src)
    main = os.path.join(d, "main.swift"); open(main, "w").write("BleCoreTests.run(%s)\n" % json.dumps(VECTORS))
    exe = os.path.join(d, "h")
    subprocess.run(["swiftc", "-O", "-o", exe, core, SWIFT_TEST, main], check=True, timeout=900)
    p = subprocess.run([exe], capture_output=True, text=True, timeout=180)
    rows = {}
    for line in p.stdout.splitlines():
        if line.startswith("{"):
            r = json.loads(line); rows[r["name"]] = (r["ok"], r.get("detail", ""))
    return rows, p.stdout + p.stderr


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("jvm", "swift"):
        sys.exit(__doc__)
    core, runner, muts = (JAVA_CORE, run_jvm, JAVA_MUTATIONS) if mode == "jvm" else (SWIFT_CORE, run_swift, SWIFT_MUTATIONS)
    muts = muts + NEW_MUTATIONS[mode]
    src = open(core, encoding="utf-8").read()
    work = tempfile.mkdtemp(prefix="blecore")
    status = 0
    try:
        rows, raw = runner(src, work, "current")
        if not rows:
            print(raw); return 1
        for n, (ok, det) in sorted(rows.items()):
            print(("PASS " if ok else "FAIL ") + n + ("" if ok else ": " + det))
            status |= 0 if ok else 1
        print("rows: %d, failed: %d" % (len(rows), sum(1 for v in rows.values() if not v[0])))
        for label, old, new, must in muts:
            if src.count(old) != 1:
                print("negative control FAILED: %s anchor found %d times" % (label, src.count(old))); status = 1; continue
            got, _ = runner(src.replace(old, new), work, label)
            if must in got and not got[must][0]:
                print("negative control ok: %s caught by %s" % (label, must))
            else:
                print("negative control FAILED: %s not caught by %s" % (label, must)); status = 1
    finally:
        shutil.rmtree(work, True)
    return status


if __name__ == "__main__":
    sys.exit(main())
