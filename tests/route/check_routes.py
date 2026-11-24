#!/usr/bin/env python3
"""check_routes.py PLATFORM PLAN.json RESULTS.jsonl : checks the route-test answers against the documented contract
(README "Calling it", "Error codes", "Platform limits"). Prints one row per route and exits 1 on any failure."""
import json, sys
platform, plan_path, res_path = sys.argv[1], sys.argv[2], sys.argv[3]
plan = json.load(open(plan_path))
STANDARD = {"bad_request", "not_registered", "forbidden_frame", "forbidden_origin", "rate_limited", "timeout",
            "unavailable", "platform_limit", "handler_error"}
EXT = {"busy", "unavailable", "permission_denied", "scan_failed", "bad_value", "unknown_device", "not_connected",
       "not_found", "not_permitted", "too_long", "connect_failed", "connect_timeout", "gatt_error", "link_lost",
       "filter_required", "advertise_failed", "no_subscribers", "platform_limit", "l2cap_failed"}
answers = {}
for line in open(res_path):
    row = json.loads(line)
    try:
        body = json.loads(row["body"])
    except ValueError:
        continue
    if isinstance(body.get("step"), int):
        answers.setdefault(body["step"], []).append(body)
fails = 0
for i, c in enumerate(plan):
    route = c["cmd"].split("extension://ble/")[1].split("?")[0]
    got = answers.get(i, [])
    problems = []
    if len(got) != 1:
        problems.append("answers=%d" % len(got))
        a = None
    else:
        a = got[0]["answer"]
    if a == "UNDEFINED" or not isinstance(a, dict):
        problems.append("no answer")
    else:
        for k, want in (("runtime", 3), ("bridge", 1), ("extension", "ble"), ("route", route), ("platform", platform)):
            if a.get(k) != want:
                problems.append("%s=%r" % (k, a.get(k)))
        if not isinstance(a.get("ok"), bool):
            problems.append("ok not bool")
        elif a["ok"]:
            if not isinstance(a.get("data"), dict):
                problems.append("data not an object")
        else:
            if a.get("data") is not None:
                problems.append("data not null on error")
            if a.get("code") not in STANDARD | EXT:
                problems.append("undocumented code %r" % a.get("code"))
            if not isinstance(a.get("error"), str) or not a["error"]:
                problems.append("no error message")
        if route == "state":
            d = a.get("data") or {}
            if not a.get("ok"):
                problems.append("state must answer")
            for k in ("state", "authorization", "run", "previousRun", "server"):
                if k not in d:
                    problems.append("state.%s missing" % k)
        if platform == "ios" and route in ("bond", "bonds") and a.get("code") != "platform_limit":
            problems.append("iOS bond routes must answer platform_limit")
        if platform == "ios" and route == "advertise_set_start" and a.get("code") != "platform_limit":
            problems.append("iOS advertising sets must answer platform_limit")
    if problems:
        fails += 1
    summary = "-" if not isinstance(a, dict) else ("ok " + json.dumps(a.get("data"))[:90] if a.get("ok")
                                                    else "%s: %s" % (a.get("code"), (a.get("error") or "")[:80]))
    print("%-4s %-18s %s%s" % ("FAIL" if problems else "PASS", route, summary, ("  <- " + "; ".join(problems)) if problems else ""))
print("routes %d, failed %d" % (len(plan), fails))
sys.exit(1 if fails else 0)
