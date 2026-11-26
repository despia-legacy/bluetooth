#!/usr/bin/env python3
"""Runs the shared BLE core vector table (tests/vectors/ble_core.json) against both cores.

  python3 -I tests/run.py jvm     # android/ble/.../BleCore.java with javac + java (JDK 17+)
  python3 -I tests/run.py swift   # ios/app/BleCore.swift with swiftc (macOS)
  python3 -I tests/run.py contract  # manifest names, README names and platform bounds

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
NEW_MUTATIONS = {  # rules added in this repo (sections "finish", "answers" and "restoration"), guarded on both cores
    "jvm": [
        ("F1", "if (!SCAN_OPTION_KEYS.contains(k)) {", "if (false) {", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F2", "if (!(n instanceof String) || !scanNames.contains(n)) return false;", "", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F3", LIMIT + '");\n            return;', LIMIT + '");', "finish_priority_and_phy_ios_are_platform_limits"),
        ("F4", '"reason", l.system ? "system" : l.background && !l.unbounded ? "auto" : "requested"', '"reason", l.system ? "system" : l.background ? "auto" : "requested"', "finish_connect_unbounded_answers_at_once_and_waits"),
        ("F5", "if (!asked.equals(previousRun)) {", "if (true) {", "finish_journal_persists_and_serves_the_previous_run"),
        ("G1", "if (c.has('a')) {", "if (false) {", "pages_answer_reads_and_writes_android"),
        ("G2", 'if (response) return "pending "', 'if (false) return "pending "', "pages_answer_reads_and_writes_android"),
        ("G3", 'if ("ok".equals(st)) for', "if (false) for", "pages_answer_reads_and_writes_android"),
        ("L1", "if (psm < 1 || psm > 255) {", "if (false) {", "l2cap_publish_open_send_close_android"),
        ("L2", 'if (!"open".equals(ch.state)) {', "if (false) {", "l2cap_publish_open_send_close_android"),
        ("X1", "if (connectable && scannable) return", "if (false) return", "advertising_sets_rules_start_stop_and_adapter_android"),
        ("X2", "if (periodic && (legacy || connectable || scannable)) {", "if (false) {", "advertising_sets_rules_start_stop_and_adapter_android"),
        ("R1", "if ((l.auto || systemReconnect) && !", "if (l.auto && !", "reconnect_system_ios_new_gen_resubscribes_without_auto"),
        ("R2", "system ? \"system\" : \"auto\"", "\"auto\"", "reconnect_system_ios_new_gen_resubscribes_without_auto"),
        ("W1", "if (services.isEmpty() && names.isEmpty() && manufacturerId < 0) {", "if (false) {", "restoration_wake_rules_start_deliver_stop_android"),
        ("W2", 'if (!list.isEmpty()) record("wake"', 'if (false) record("wake"', "restoration_wake_relaunch_failure_and_refusal_android"),
        ("W3", 'record("wake", obj("state", "failed", "error", error));', "", "restoration_wake_relaunch_failure_and_refusal_android"),
        ("C1", "if (address != null && !(address instanceof String", "if (false && !(address instanceof String", "restoration_companion_associate_presence_android"),
        ("P1", "fail(call, \"platform_limit\", PRESENCE_LIMIT);\n            return;", "fail(call, \"platform_limit\", PRESENCE_LIMIT);", "restoration_ios_wake_presence_are_platform_limits_associate_is_accessory_setup_kit"),
        ("P2", "if (association > 0) observing.add(association);", "", "restoration_presence_relaunch_android"),
        ("B1", "if (wake && (sdk == 29 || sdk == 30)) runtime.add(BACKGROUND_LOCATION);", "", "permissions_by_api_level_and_role"),
        ("B2", "boolean scan = \"scan\".equals(role) || \"central\".equals(role) || wake;", "boolean scan = \"scan\".equals(role) || \"central\".equals(role);", "permissions_by_api_level_and_role"),
        ("I1", 'if (raw.get("address") != null) {\n                fail(call, "bad_value", ASSOCIATE_IOS_ADDRESS);', 'if (false) {\n                fail(call, "bad_value", ASSOCIATE_IOS_ADDRESS);', "restoration_ios_wake_presence_are_platform_limits_associate_is_accessory_setup_kit"),
        ("I2", 'if (services.isEmpty() && manufacturerId < 0) {\n                fail(call, "bad_value", "services is one service UUID or manufacturer_id is a company identifier: the iOS', 'if (false) {\n                fail(call, "bad_value", "services is one service UUID or manufacturer_id is a company identifier: the iOS', "associate_company_identifier_migration_and_failures_ios"),
    ],
    "swift": [
        ("F1", "for k in options.keys where !BleCore.scanOptionKeys.contains(k) {", "for k in options.keys where false {", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F2", 'guard let n = adv["name"] as? String, scanNames.contains(n) else { return false }', "_ = adv", "finish_scan_filters_by_name_and_manufacturer_with_android_options"),
        ("F3", LIMIT + '")\n            return\n', LIMIT + '")\n', "finish_priority_and_phy_ios_are_platform_limits"),
        ("F4", '("reason", l.system ? "system" : l.background && !l.unbounded ? "auto" : "requested")', '("reason", l.system ? "system" : l.background ? "auto" : "requested")', "finish_connect_unbounded_answers_at_once_and_waits"),
        ("F5", "guard r == previousRun else {", "guard false else {", "finish_journal_persists_and_serves_the_previous_run"),
        ("G1", 'if c.has("a") {', "if false {", "pages_answer_reads_and_writes_ios"),
        ("G2", 'if response { return "pending ', 'if false { return "pending ', "pages_answer_reads_and_writes_ios"),
        ("G3", 'if st == "ok" { for', "if false { for", "pages_answer_reads_and_writes_android"),
        ("L1", "if psm < 1 || psm > 255 {", "if false {", "l2cap_publish_open_send_close_android"),
        ("L2", 'if ch.state != "open" {', "if false {", "l2cap_publish_open_send_close_android"),
        ("L3", 'rec["reason"] = code == nil ? "remote" : "error"', 'rec["reason"] = "remote"', "l2cap_ios_stream_error_and_adapter_off"),
        ("X1", "if connectable && scannable { return", "if false { return", "advertising_sets_rules_start_stop_and_adapter_android"),
        ("X2", "if periodic && (legacy || connectable || scannable) {", "if false {", "advertising_sets_rules_start_stop_and_adapter_android"),
        ("X3", 'fail(call, "platform_limit", BleCore.advSetLimit)\n            return\n', 'fail(call, "platform_limit", BleCore.advSetLimit)\n', "advertising_sets_ios_is_a_platform_limit"),
        ("R1", "if (l.auto || systemReconnect) && reason", "if l.auto && reason", "reconnect_system_ios_new_gen_resubscribes_without_auto"),
        ("R2", 'system ? "system" : "auto"', '"auto"', "reconnect_system_ios_new_gen_resubscribes_without_auto"),
        ("W1", "if services.isEmpty && names.isEmpty && manufacturerId < 0 {", "if false {", "restoration_wake_rules_start_deliver_stop_android"),
        ("W2", 'if !list.isEmpty { record("wake"', 'if false { record("wake"', "restoration_wake_relaunch_failure_and_refusal_android"),
        ("W3", 'record("wake", BleCore.obj(("state", "failed"), ("error", error)))', "", "restoration_wake_relaunch_failure_and_refusal_android"),
        ("C1", "if let a = address, !(a is NSNull) {", "if false, let a = address {", "restoration_companion_associate_presence_android"),
        ("P1", 'fail(call, "platform_limit", BleCore.presenceLimit)\n            return\n', 'fail(call, "platform_limit", BleCore.presenceLimit)\n', "restoration_ios_wake_presence_are_platform_limits_associate_is_accessory_setup_kit"),
        ("P2", "if association > 0 && !observing.contains(association) { observing.append(association) }", "", "restoration_presence_relaunch_android"),
        ("I1", 'if let a = raw["address"], !(a is NSNull) {\n                fail(call, "bad_value", BleCore.associateIOSAddress)', 'if false {\n                fail(call, "bad_value", BleCore.associateIOSAddress)', "restoration_ios_wake_presence_are_platform_limits_associate_is_accessory_setup_kit"),
        ("I2", 'if services.isEmpty && manufacturerId < 0 {\n                fail(call, "bad_value", "services is one service UUID or manufacturer_id is a company identifier: the iOS', 'if false {\n                fail(call, "bad_value", "services is one service UUID or manufacturer_id is a company identifier: the iOS', "associate_company_identifier_migration_and_failures_ios"),
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


MANIFEST = os.path.join(ROOT, "manifest.json")
README = os.path.join(ROOT, "README.md")
# Numeric bounds the platform documents for a parameter it takes as is. A manifest bound narrower
# than the platform's refuses a value the platform accepts (a feature cut); wider lets through a
# value the platform throws on. Each row: route, parameter, min, max, source (read 2026-11-25).
PLATFORM_BOUNDS = [
    ("advertise_set_start", "tx_power_dbm", -127, 20,
     "https://developer.android.com/reference/android/bluetooth/le/AdvertisingSetParameters.Builder#setTxPowerLevel(int)"),
    ("advertise_set_start", "interval_ms", 100, 10485759,
     "https://developer.android.com/reference/android/bluetooth/le/AdvertisingSetParameters.Builder#setInterval(int)"),
]


def camel(name):
    return "".join(p[:1].upper() + p[1:] for p in name.split("_"))


def contract_problems(manifest, readme):
    """The names a page uses: every answer variable and callback is the route or event name in
    camelCase (`l2cap_open` -> `bleL2capOpen`, `onBleL2capOpen`), one spelling for the whole
    extension; every `ble*` / `onBle*` name the README tells a page to use exists in the manifest;
    every numeric bound in PLATFORM_BOUNDS matches the platform's documented range."""
    import re
    bridge = manifest["bridge"]
    names, problems = set(), []
    for r in bridge["routes"]:
        out = r.get("output", {})
        for key, want in (("variable", "ble" + camel(r["name"])), ("callback", "onBle" + camel(r["name"]))):
            got = out.get(key)
            names.add(got)
            if got != want:
                problems.append("route %s: %s is %s, the name rule gives %s" % (r["name"], key, got, want))
    for e in bridge.get("events", []):
        want = "onBle" + camel(e["name"])
        names.add(e.get("callback"))
        if e.get("callback") != want:
            problems.append("event %s: callback is %s, the name rule gives %s" % (e["name"], e.get("callback"), want))
    for n in sorted(set(re.findall(r"\b(?:ble|onBle)[A-Z][A-Za-z0-9]*\b", readme))):
        if n not in names:
            problems.append("README names %s, which the manifest does not declare" % n)
    routes = {r["name"]: r for r in bridge["routes"]}
    for route, param, lo, hi, src in PLATFORM_BOUNDS:
        p = routes.get(route, {}).get("params", {}).get(param)
        if p is None or p.get("min") != lo or p.get("max") != hi:
            problems.append("%s.%s bounds %s, the platform documents [%d, %d] (%s)" % (
                route, param, None if p is None else [p.get("min"), p.get("max")], lo, hi, src))
    return problems


def run_contract():
    manifest = json.load(open(MANIFEST, encoding="utf-8"))
    readme = open(README, encoding="utf-8").read()
    problems = contract_problems(manifest, readme)
    for p in problems:
        print("FAIL " + p)
    # Negative controls: the check must catch a drifted name and a cut bound.
    bad = json.loads(json.dumps(manifest))
    bad["bridge"]["routes"][0]["output"]["variable"] += "X"
    caught = [bool(contract_problems(bad, readme))]
    caught.append(bool(contract_problems(manifest, readme + "\n`bleNoSuchRoute`\n")))
    bad = json.loads(json.dumps(manifest))
    for r in bad["bridge"]["routes"]:
        if r["name"] == PLATFORM_BOUNDS[0][0]:
            r["params"][PLATFORM_BOUNDS[0][1]]["max"] = 1
    caught.append(bool(contract_problems(bad, readme)))
    for i, c in enumerate(caught):
        print("negative control %s: C%d" % ("ok" if c else "FAILED", i + 1))
    print("contract problems: %d" % len(problems))
    return 0 if not problems and all(caught) else 1


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "contract":
        return run_contract()
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
