package nxtest;

import despia.ext.ble.BleCore;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Runs the shared BLE core vector table (scripts/native_ext/tests/vectors/ble_core.json) against
 * fixtures/ble/.../BleCore.java on a plain JVM. The Swift twin runs the same table in d-ios
 * (tests/swift/ble_core_tests.swift). Each step names one core input; the fake port writes every
 * port call as one canonical line, and the lines must equal the step's "out" exactly. Prints PASS or
 * FAIL per scenario and per codec section; exits 1 on any failure. No radio, device or Android class
 * is involved: this proves the core's decisions only.
 *   java nxtest.BleCoreTest VECTORS.json [--print]
 */
public final class BleCoreTest {
    static int failures;

    // ---- a small ordered JSON reader (org.json is not on a plain JVM) ---------------------------

    static final class Reader {
        final String s;
        int i;

        Reader(String s) {
            this.s = s;
        }

        void ws() {
            while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
        }

        Object value() {
            ws();
            char c = s.charAt(i);
            if (c == '{') {
                i++;
                Map<String, Object> m = new LinkedHashMap<>();
                ws();
                if (s.charAt(i) == '}') {
                    i++;
                    return m;
                }
                while (true) {
                    ws();
                    String k = (String) value();
                    ws();
                    i++; // ':'
                    m.put(k, value());
                    ws();
                    if (s.charAt(i++) == '}') return m;
                }
            }
            if (c == '[') {
                i++;
                List<Object> l = new ArrayList<>();
                ws();
                if (s.charAt(i) == ']') {
                    i++;
                    return l;
                }
                while (true) {
                    l.add(value());
                    ws();
                    if (s.charAt(i++) == ']') return l;
                }
            }
            if (c == '"') {
                StringBuilder b = new StringBuilder();
                i++;
                while (s.charAt(i) != '"') {
                    char ch = s.charAt(i++);
                    if (ch == '\\') {
                        char e = s.charAt(i++);
                        if (e == 'u') {
                            b.append((char) Integer.parseInt(s.substring(i, i + 4), 16));
                            i += 4;
                        } else b.append(e == 'n' ? '\n' : e == 't' ? '\t' : e);
                    } else b.append(ch);
                }
                i++;
                return b.toString();
            }
            if (s.startsWith("true", i)) {
                i += 4;
                return Boolean.TRUE;
            }
            if (s.startsWith("false", i)) {
                i += 5;
                return Boolean.FALSE;
            }
            if (s.startsWith("null", i)) {
                i += 4;
                return null;
            }
            int j = i;
            while (j < s.length() && "-0123456789".indexOf(s.charAt(j)) >= 0) j++;
            int v = Integer.parseInt(s.substring(i, j));
            i = j;
            return v;
        }
    }

    // ---- the fake port ----------------------------------------------------------------------------

    static final class Fake implements BleCore.Port {
        final List<String> out = new ArrayList<>();
        final Map<String, String> refuse = new HashMap<>();
        final Set<Integer> expired = new HashSet<>();
        /** What notify answers when no refusal is scripted: null (handed over now) or "pending". */
        String notifyMode;
        boolean closeNow;
        long now;

        private String take(String kind) {
            return refuse.remove(kind);
        }

        public String scanStart(int scan, List<String> services, boolean duplicates, String mode, Map<String, Object> options) {
            out.add("scan_start " + scan + " " + (services.isEmpty() ? "-" : String.join(",", services)) + " " + duplicates + " " + mode
                    + (options.isEmpty() ? "" : " " + BleCore.json(options)));
            return take("scan_start");
        }

        public void scanStop(int scan) {
            out.add("scan_stop " + scan);
        }

        public String connect(String id, int gen, boolean auto, boolean background) {
            out.add("connect " + id + " " + gen + " " + auto + " " + background);
            return take("connect");
        }

        public boolean close(String id, int gen) {
            out.add("close " + id + " " + gen);
            return closeNow;
        }

        public void release(String id, int gen) {
            out.add("release " + id + " " + gen);
        }

        public String op(String id, int gen, int op, String kind, String key, String descriptor, byte[] data, int arg) {
            out.add("op " + id + " " + gen + " " + op + " " + kind + " " + (key == null ? "-" : key) + " "
                    + (descriptor == null ? "-" : descriptor) + " " + (data == null ? "-" : BleCore.hex(data)) + " " + arg);
            return take("op");
        }

        public String writable(String id, int gen, boolean withResponse) {
            out.add("writable " + id + " " + gen + " " + withResponse);
            return take("writable");
        }

        public void timer(String kind, int token, long ms) {
            out.add("timer " + kind + " " + token + " " + ms);
        }

        final Map<Integer, String> messages = new HashMap<>();

        public void reply(int call, boolean ok, String code, String message, Map<String, Object> data) {
            out.add(ok ? "reply " + call + " ok " + BleCore.json(data) : "reply " + call + " error " + code);
            if (!ok) messages.put(call, message == null ? "" : message);
        }

        public void emit(String event, Map<String, Object> data) {
            out.add("emit " + event + " " + BleCore.json(data));
        }

        public boolean isActive(int call) {
            return !expired.contains(call);
        }

        public long now() {
            return now;
        }

        public void stale(String what) {
            out.add("stale " + what);
        }

        public String serviceAdd(int epoch, String uuid, boolean primary, List<Map<String, Object>> chars) {
            out.add("service_add " + epoch + " " + uuid + " " + primary + " " + BleCore.json(chars));
            return take("service_add");
        }

        public void serviceRemove(String uuid) {
            out.add("service_remove " + uuid);
        }

        public String advertiseStart(int epoch, int adv, Map<String, Object> params) {
            out.add("advertise_start " + epoch + " " + adv + " " + BleCore.json(params));
            return take("advertise_start");
        }

        public void advertiseStop(int adv) {
            out.add("advertise_stop " + adv);
        }

        public String notify(int epoch, int packet, String central, String key, byte[] data, boolean indicate) {
            out.add("notify " + epoch + " " + packet + " " + central + " " + key + " " + BleCore.hex(data) + " " + indicate);
            String r = take("notify");
            return r == null ? notifyMode : "-".equals(r) ? null : r;
        }

        public void centralDrop(String central) {
            out.add("central_drop " + central);
        }

        public String keepAlive(boolean start, int hold) {
            out.add("keep_alive " + start + " " + hold);
            return start ? take("keep_alive") : null;
        }

        public void persist(Map<String, Object> snapshot) {
            out.add("persist " + BleCore.json(snapshot));
        }

        public String attRespond(int epoch, int request, String status, int offset, byte[] data) {
            out.add("att_respond " + epoch + " " + request + " " + status + " " + offset + " " + (data == null ? "-" : BleCore.hex(data)));
            return take("att_respond");
        }

        public String l2capPublish(int epoch, int t, boolean encrypted) {
            out.add("l2cap_publish " + epoch + " " + t + " " + encrypted);
            return take("l2cap_publish");
        }

        public void l2capUnpublish(int psm) {
            out.add("l2cap_unpublish " + psm);
        }

        public String l2capOpen(int epoch, int channel, String id, int psm, boolean encrypted) {
            out.add("l2cap_open " + epoch + " " + channel + " " + id + " " + psm + " " + encrypted);
            return take("l2cap_open");
        }

        public String l2capSend(int channel, byte[] data) {
            out.add("l2cap_send " + channel + " " + BleCore.hex(data));
            return take("l2cap_send");
        }

        public void l2capClose(int channel) {
            out.add("l2cap_close " + channel);
        }

        public String advertiseSetStart(int epoch, int set, Map<String, Object> params) {
            out.add("advertise_set_start " + epoch + " " + set + " " + BleCore.json(params));
            return take("advertise_set_start");
        }

        public void advertiseSetStop(int set) {
            out.add("advertise_set_stop " + set);
        }
    }

    // ---- step driver ------------------------------------------------------------------------------

    static String str(Map<String, Object> st, String k) {
        Object v = st.get(k);
        return v == null ? null : (String) v;
    }

    static int num(Map<String, Object> st, String k, int dflt) {
        Object v = st.get(k);
        return v == null ? dflt : (Integer) v;
    }

    static boolean flag(Map<String, Object> st, String k, boolean dflt) {
        Object v = st.get(k);
        return v == null ? dflt : (Boolean) v;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> map(Map<String, Object> st, String k) {
        Object v = st.get(k);
        return v == null ? null : (Map<String, Object>) v;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> errorArg(Object v) {
        if (v == null) return null;
        // The radio's form: the core's platformError, so the name table is exercised.
        Map<String, Object> m = (Map<String, Object>) v;
        return BleCore.platformError((String) m.get("domain"), ((Number) m.get("code")).intValue(), (String) m.get("message"));
    }

    static void step(BleCore core, Fake port, Map<String, Object> st) {
        String d = str(st, "do");
        int call = num(st, "call", -1);
        switch (d) {
            case "port":
                if (st.containsKey("refuse")) port.refuse.putAll((Map<String, String>) (Map<?, ?>) map(st, "refuse"));
                if (st.containsKey("close_now")) port.closeNow = flag(st, "close_now", false);
                if (st.containsKey("now")) port.now = num(st, "now", 0);
                if (st.containsKey("notify_mode")) port.notifyMode = str(st, "notify_mode");
                return;
            case "expire":
                port.expired.add(call);
                return;
            case "adapter":
                core.adapter(str(st, "state"));
                return;
            case "state":
                port.out.add("state " + BleCore.json(core.stateFields()));
                return;
            case "stale_count":
                port.out.add("stale_count " + core.staleDrops);
                return;
            case "scan_start":
                core.scanStart(call, str(st, "services"), num(st, "seconds", 0), flag(st, "duplicates", false),
                        st.containsKey("mode") ? str(st, "mode") : "balanced", flag(st, "background", false),
                        str(st, "names"), num(st, "manufacturer_id", -1), str(st, "manufacturer_hex"),
                        st.containsKey("options") ? new LinkedHashMap<>(map(st, "options")) : BleCore.obj());
                return;
            case "scan_stop":
                core.scanStop(call);
                return;
            case "device":
                core.device(num(st, "scan", 0), str(st, "id"), map(st, "adv"));
                return;
            case "scan_failed":
                core.scanFailed(num(st, "scan", 0), "failed");
                return;
            case "background":
                core.background(flag(st, "value", true));
                return;
            case "devices":
                core.devices(call);
                return;
            case "connect":
                core.connect(call, str(st, "id"), flag(st, "auto", false), num(st, "seconds", 10));
                return;
            case "connected":
                core.connected(str(st, "id"), num(st, "gen", 0), num(st, "mtu", 23));
                return;
            case "disconnected":
                core.disconnected(str(st, "id"), num(st, "gen", 0), st.containsKey("reason") ? str(st, "reason") : "remote",
                        errorArg(st.get("error")), flag(st, "reconnecting", false));
                return;
            case "message":
                port.out.add("message " + call + " " + port.messages.getOrDefault(call, "-"));
                return;
            case "disconnect":
                core.disconnect(call, str(st, "id"));
                return;
            case "links":
                core.links(call);
                return;
            case "discover":
                core.discover(call, str(st, "id"));
                return;
            case "read":
                core.read(call, str(st, "id"), str(st, "service"), num(st, "service_n", 0), str(st, "char"), num(st, "char_n", 0),
                        str(st, "descriptor"));
                return;
            case "write":
                core.write(call, str(st, "id"), str(st, "service"), num(st, "service_n", 0), str(st, "char"), num(st, "char_n", 0),
                        str(st, "descriptor"), str(st, "hex"), str(st, "b64"), flag(st, "response", true), str(st, "text"));
                return;
            case "raw":
                core.raw(call, str(st, "id"), str(st, "hex"), str(st, "b64"), str(st, "text"), flag(st, "response", true));
                return;
            case "priority":
                core.priority(call, str(st, "id"), str(st, "level"));
                return;
            case "phy":
                core.phy(call, str(st, "id"), str(st, "tx"), str(st, "rx"), st.containsKey("coded") ? str(st, "coded") : "none");
                return;
            case "phy_changed":
                core.phyChanged(str(st, "id"), num(st, "gen", 0), str(st, "tx"), str(st, "rx"), str(st, "code"));
                return;
            case "external":
                core.external(str(st, "event"), map(st, "data"));
                return;
            case "journal_persist": {
                Object[] j = core.journalToPersist();
                port.out.add(j == null ? "journal -" : "journal " + j[1] + " " + BleCore.json(j[0]));
                return;
            }
            case "load_previous": {
                List<Map<String, Object>> recs = new ArrayList<>();
                for (Object o : (List<Object>) st.get("records")) recs.add((Map<String, Object>) o);
                core.loadPrevious(str(st, "run"), recs);
                return;
            }
            case "subscribe":
            case "unsubscribe":
                core.subscribe(call, str(st, "id"), str(st, "service"), num(st, "service_n", 0), str(st, "char"), num(st, "char_n", 0),
                        "subscribe".equals(d));
                return;
            case "rssi":
                core.rssi(call, str(st, "id"));
                return;
            case "mtu":
                core.mtu(call, str(st, "id"), num(st, "size", 517));
                return;
            case "op_done":
                core.opDone(str(st, "id"), num(st, "gen", 0), num(st, "op", 0), str(st, "code"), str(st, "message"), map(st, "data"));
                return;
            case "mtu_changed":
                core.mtuChanged(str(st, "id"), num(st, "gen", 0), num(st, "mtu", 23), flag(st, "success", true));
                return;
            case "value":
                core.value(str(st, "id"), num(st, "gen", 0), str(st, "key"), str(st, "hex"), flag(st, "maybe_read", false));
                return;
            case "gatt_changed":
                core.gattChanged(str(st, "id"), num(st, "gen", 0));
                return;
            case "timer":
                core.timer(str(st, "kind"), num(st, "token", 0));
                return;
            case "events":
                core.events(call, num(st, "after", 0), num(st, "max", 200), str(st, "run"));
                return;
            case "restored": {
                List<String> subs = new ArrayList<>();
                Object l = st.get("subscribed");
                if (l != null) for (Object o : (List<Object>) l) subs.add((String) o);
                port.out.add("gen " + core.restored(str(st, "id"), flag(st, "connected", true), subs, flag(st, "pending", false)));
                return;
            }
            case "restored_event":
                core.restoredEvent((Map<String, Object>) st.get("data"));
                return;
            case "service_add":
                core.serviceAdd(call, str(st, "uuid"), flag(st, "primary", true), str(st, "chars"));
                return;
            case "service_added":
                core.serviceAdded(num(st, "epoch", 1), str(st, "uuid"), str(st, "code"));
                return;
            case "service_remove":
                core.serviceRemove(call, str(st, "uuid"));
                return;
            case "services":
                core.services(call);
                return;
            case "value_set":
                core.valueSet(call, str(st, "service"), str(st, "char"), num(st, "char_n", 0), str(st, "hex"), str(st, "b64"),
                        str(st, "text"));
                return;
            case "notify":
                core.notify(call, str(st, "service"), str(st, "char"), num(st, "char_n", 0), str(st, "hex"), str(st, "b64"),
                        str(st, "central"), str(st, "text"));
                return;
            case "notify_sent":
                core.notifySent(num(st, "epoch", 1), num(st, "packet", 0), str(st, "code"));
                return;
            case "notify_ready":
                core.notifyReady(num(st, "epoch", 1));
                return;
            case "central_connected":
                core.centralConnected(num(st, "epoch", 1), str(st, "central"), num(st, "mtu", 23));
                return;
            case "central_mtu":
                core.centralMtu(num(st, "epoch", 1), str(st, "central"), num(st, "mtu", 23));
                return;
            case "central_disconnected":
                core.centralDisconnected(num(st, "epoch", 1), str(st, "central"));
                return;
            case "subscription":
                port.out.add("status " + core.subscription(num(st, "epoch", 1), str(st, "central"), num(st, "mtu", 23),
                        str(st, "key"), str(st, "mode")));
                return;
            case "cccd":
                port.out.add("cccd " + core.cccd(str(st, "central"), str(st, "key")));
                return;
            case "read_request":
                port.out.add("answer " + BleCore.json(core.readRequest(num(st, "epoch", 1), str(st, "central"), num(st, "mtu", 23),
                        str(st, "key"), num(st, "offset", 0))));
                return;
            case "write_request": {
                List<Map<String, Object>> reqs = new ArrayList<>();
                for (Object o : (List<Object>) st.get("requests")) reqs.add((Map<String, Object>) o);
                port.out.add("status " + core.writeRequests(num(st, "epoch", 1), str(st, "central"), num(st, "mtu", 23), reqs,
                        flag(st, "prepare", false)));
                return;
            }
            case "execute_write":
                port.out.add("status " + core.executeWrite(num(st, "epoch", 1), str(st, "central"), flag(st, "execute", true)));
                return;
            case "centrals":
                core.centrals(call);
                return;
            case "central_drop":
                core.centralDrop(call, str(st, "central"));
                return;
            case "advertise_start":
                core.advertiseStart(call, str(st, "services"), str(st, "name"), num(st, "manufacturer_id", -1),
                        str(st, "manufacturer_hex"), str(st, "service_data_uuid"), str(st, "service_data_hex"),
                        flag(st, "connectable", true), st.containsKey("mode") ? str(st, "mode") : "balanced", num(st, "seconds", 0),
                        str(st, "tx_power"), st.containsKey("include_tx_power") ? (Boolean) st.get("include_tx_power") : null);
                return;
            case "advertise_started":
                core.advertiseStarted(num(st, "epoch", 1), num(st, "adv", 0), str(st, "code"));
                return;
            case "advertise_stop":
                core.advertiseStop(call);
                return;
            case "keep_alive":
                core.keepAlive(call, flag(st, "enabled", true), flag(st, "background_modes", true));
                return;
            case "hold_current":
                port.out.add("hold_current " + core.holdCurrent(num(st, "hold", 0)));
                return;
            case "hold_count":
                port.out.add("hold_count " + core.holdCount());
                return;
            case "respond":
                core.respond(call, num(st, "request", 0), str(st, "status"), str(st, "hex"), str(st, "b64"), str(st, "text"),
                        num(st, "offset", -1));
                return;
            case "l2cap_publish":
                core.l2capPublish(call, flag(st, "encrypted", false));
                return;
            case "l2cap_published":
                core.l2capPublished(num(st, "epoch", 1), num(st, "t", 1), num(st, "psm", 0), str(st, "code"));
                return;
            case "l2cap_unpublish":
                core.l2capUnpublish(call, num(st, "psm", 0));
                return;
            case "l2cap_incoming":
                port.out.add("channel " + core.l2capIncoming(num(st, "epoch", 1), num(st, "psm", 0), str(st, "peer")));
                return;
            case "l2cap_open":
                core.l2capOpen(call, str(st, "id"), num(st, "psm", 0), flag(st, "encrypted", false), num(st, "seconds", 0));
                return;
            case "l2cap_opened":
                core.l2capOpened(num(st, "epoch", 1), num(st, "channel", 0), str(st, "code"));
                return;
            case "l2cap_send":
                core.l2capSend(call, num(st, "channel", 0), str(st, "hex"), str(st, "b64"), str(st, "text"));
                return;
            case "l2cap_data":
                core.l2capData(num(st, "channel", 0), str(st, "hex"));
                return;
            case "l2cap_closed":
                core.l2capClosed(num(st, "channel", 0), str(st, "code"));
                return;
            case "l2cap_close":
                core.l2capClose(call, num(st, "channel", 0));
                return;
            case "l2cap_channels":
                core.l2capChannels(call);
                return;
            case "advertise_set_start":
                core.advertiseSetStart(call, map(st, "params"));
                return;
            case "advertise_set_started":
                core.advertiseSetStarted(num(st, "epoch", 1), num(st, "set", 0), num(st, "tx_power", 0), str(st, "code"));
                return;
            case "advertise_set_stopped":
                core.advertiseSetStopped(num(st, "epoch", 1), num(st, "set", 0));
                return;
            case "advertise_set_stop":
                core.advertiseSetStop(call, num(st, "set", 0));
                return;
            default:
                throw new IllegalArgumentException("unknown step " + d);
        }
    }

    @SuppressWarnings("unchecked")
    static List<String> strings(Object o) {
        List<String> out = new ArrayList<>();
        if (o != null) for (Object x : (List<Object>) o) out.add((String) x);
        return out;
    }

    @SuppressWarnings("unchecked")
    static void scenario(Map<String, Object> sc, boolean print) {
        String name = (String) sc.get("name");
        Fake port = new Fake();
        BleCore core = new BleCore(port, (String) sc.get("platform"), "r1");
        List<Object> steps = (List<Object>) sc.get("steps");
        try {
            for (int k = 0; k < steps.size(); k++) {
                Map<String, Object> st = (Map<String, Object>) steps.get(k);
                port.out.clear();
                int repeat = num(st, "repeat", 1);
                for (int r = 0; r < repeat; r++) {
                    Map<String, Object> one = new LinkedHashMap<>(st);
                    if (st.containsKey("call")) one.put("call", num(st, "call", 0) + r);
                    step(core, port, one);
                }
                List<String> want = strings(st.get("out"));
                if (print) {
                    System.out.println("STEP " + BleCore.json(BleCore.obj("scenario", name, "step", k, "out", new ArrayList<Object>(port.out))));
                    continue;
                }
                if (!port.out.equals(want)) {
                    throw new AssertionError("step " + k + " (" + st.get("do") + "): got " + port.out + " want " + want);
                }
            }
            System.out.println("PASS " + name);
        } catch (Throwable t) {
            failures++;
            System.out.println("FAIL " + name + ": " + t);
        }
    }

    // ---- codec rows -------------------------------------------------------------------------------

    static Object codec(String fn, List<Object> in) {
        switch (fn) {
            case "hex":
                return BleCore.hex(BleCore.fromHex((String) in.get(0)));
            case "fromHex": {
                byte[] b = BleCore.fromHex((String) in.get(0));
                return b == null ? null : BleCore.hex(b);
            }
            case "fromB64": {
                byte[] b = BleCore.fromB64((String) in.get(0));
                return b == null ? null : BleCore.hex(b);
            }
            case "uuid":
                return BleCore.uuid((String) in.get(0));
            case "uuidList": {
                List<String> l = BleCore.uuidList((String) in.get(0));
                return l == null ? null : new ArrayList<Object>(l);
            }
            case "isId":
                return BleCore.isId((String) in.get(0), (String) in.get(1));
            case "bytes": {
                byte[] b = BleCore.bytes((String) in.get(0), (String) in.get(1), in.size() > 2 ? (String) in.get(2) : null);
                return b == null ? null : BleCore.hex(b);
            }
            case "nameList": {
                List<String> l = BleCore.nameList((String) in.get(0));
                return l == null ? null : new ArrayList<Object>(l);
            }
            case "phyList": {
                List<String> l = BleCore.phyList((String) in.get(0));
                return l == null ? null : new ArrayList<Object>(l);
            }
            default:
                return extra(fn, in);
        }
    }

    /** Codec functions added by later sections. */
    static Object extra(String fn, List<Object> in) {
        if ("chars".equals(fn)) {
            List<Map<String, Object>> l = BleCore.parseChars((String) in.get(0));
            return l == null ? null : new ArrayList<Object>(l);
        }
        throw new IllegalArgumentException("unknown codec function " + fn);
    }

    @SuppressWarnings("unchecked")
    public static void main(String[] args) throws Exception {
        String text = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);
        boolean print = args.length > 1 && "--print".equals(args[1]);
        Map<String, Object> doc = (Map<String, Object>) new Reader(text).value();
        Map<String, Object> sections = (Map<String, Object>) doc.get("sections");
        for (Map.Entry<String, Object> sec : sections.entrySet()) {
            Map<String, Object> s = (Map<String, Object>) sec.getValue();
            if (s.containsKey("cases")) {
                int bad = 0;
                for (Object c : (List<Object>) s.get("cases")) {
                    Map<String, Object> row = (Map<String, Object>) c;
                    Object got;
                    try {
                        got = codec((String) row.get("fn"), (List<Object>) row.get("in"));
                    } catch (RuntimeException e) {
                        got = "threw " + e.getClass().getSimpleName();
                    }
                    String g = BleCore.json(got), w = BleCore.json(row.get("out"));
                    if (!g.equals(w)) {
                        bad++;
                        System.out.println("  " + sec.getKey() + " " + row.get("fn") + BleCore.json(row.get("in")) + ": got " + g + " want " + w);
                    }
                }
                if (bad == 0) System.out.println("PASS " + sec.getKey());
                else {
                    failures++;
                    System.out.println("FAIL " + sec.getKey() + ": " + bad + " cases");
                }
            }
            if (s.containsKey("scenarios")) {
                for (Object sc : (List<Object>) s.get("scenarios")) scenario((Map<String, Object>) sc, print);
            }
        }
        permissionMatrix();
        System.out.println(failures == 0 ? "ALL PASS" : failures + " FAILED");
        System.exit(failures == 0 ? 0 : 1);
    }

    /**
     * BL-P11, Android only (iOS has one Bluetooth authorization, so the shared table has no rows for
     * it): BleCore.permissions by API level, role and neverForLocation, as {install, runtime}.
     */
    static void permissionMatrix() {
        String bt = "android.permission.BLUETOOTH", admin = "android.permission.BLUETOOTH_ADMIN";
        String scan = "android.permission.BLUETOOTH_SCAN", connect = "android.permission.BLUETOOTH_CONNECT";
        String adv = "android.permission.BLUETOOTH_ADVERTISE", fine = "android.permission.ACCESS_FINE_LOCATION";
        Object[][] rows = {
                {30, "scan", false, Arrays.asList(bt, admin), Arrays.asList(fine)},
                {30, "scan", true, Arrays.asList(bt, admin), Arrays.asList(fine)},
                {30, "connect", false, Arrays.asList(bt), Arrays.asList()},
                {30, "central", false, Arrays.asList(bt, admin), Arrays.asList(fine)},
                {30, "advertise", false, Arrays.asList(bt, admin), Arrays.asList()},
                {24, "connect", true, Arrays.asList(bt), Arrays.asList()},
                {31, "scan", false, Arrays.asList(), Arrays.asList(scan, fine)},
                {31, "scan", true, Arrays.asList(), Arrays.asList(scan)},
                {31, "connect", false, Arrays.asList(), Arrays.asList(connect)},
                {33, "central", false, Arrays.asList(), Arrays.asList(scan, fine, connect)},
                {34, "central", true, Arrays.asList(), Arrays.asList(scan, connect)},
                {34, "advertise", false, Arrays.asList(), Arrays.asList(adv, connect)},
                {36, "advertise", true, Arrays.asList(), Arrays.asList(adv, connect)},
                {36, "scan", false, Arrays.asList(), Arrays.asList(scan, fine)},
                {24, "advertise", false, Arrays.asList(bt, admin), Arrays.asList()},
        };
        List<String> bad = new ArrayList<>();
        for (Object[] r : rows) {
            List<List<String>> got = BleCore.permissions((Integer) r[0], (String) r[1], (Boolean) r[2]);
            List<Object> want = Arrays.asList(r[3], r[4]);
            if (!got.equals(want)) bad.add(r[0] + " " + r[1] + " " + r[2] + ": got " + got + " want " + want);
        }
        if (bad.isEmpty()) System.out.println("PASS permissions_by_api_level_and_role");
        else {
            failures++;
            System.out.println("FAIL permissions_by_api_level_and_role: " + bad);
        }
    }
}
