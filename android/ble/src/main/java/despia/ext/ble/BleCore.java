package despia.ext.ble;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Every decision of the BLE extension, as one state machine on the main thread. Pure Java: no
 * android import, so the same test table runs against this class on a
 * plain JVM and against its Swift twin BleCore.swift. The radio files only translate platform
 * callbacks into the inputs below and execute what the {@link Port} is asked to do.
 *
 * <p>Tokens. {@code gen} names one connection attempt, {@code scan} one scan, {@code op} one GATT
 * operation step; all come from counters that never repeat in a process. Every radio callback and
 * every timer carries its token back; one whose token is not current changes nothing, replies to
 * nothing and is counted as a stale drop (rules 1, 2 and 7 of the design).
 *
 * <p>Port calls never call back into the core: what the platform confirms at once comes back as the
 * return value (an error text, or {@code true} for a close that needs no callback).
 */
public final class BleCore {

    /** What the core asks of the platform side. Implemented by the radio adapter and by test fakes. */
    public interface Port {
        /** Start a scan. Returns null when the platform accepted it, else "code message". */
        String scanStart(int scan, List<String> services, boolean duplicates, String mode);

        void scanStop(int scan);

        /** Start connection attempt {@code gen}. {@code background}: an automatic reconnect. */
        String connect(String id, int gen, boolean auto, boolean background);

        /** Begin closing {@code gen}. True when the platform confirmed the close now (no callback follows). */
        boolean close(String id, int gen);

        /** The close of {@code gen} was not confirmed in time: release the platform object without waiting. */
        void release(String id, int gen);

        /**
         * Hand one GATT step to the platform. Kinds: mtu (arg = size), discover, read, write
         * (with response), wnr (one chunk without response), sub, unsub, rssi. Returns null when
         * the platform accepted it, else "code message" (the step settles at once).
         */
        String op(String id, int gen, int op, String kind, String key, String descriptor, byte[] data, int arg);

        void timer(String kind, int token, long ms);

        void reply(int call, boolean ok, String code, String message, Map<String, Object> data);

        void emit(String event, Map<String, Object> data);

        boolean isActive(int call);

        long now();

        /** A callback or timer for a token that is no longer current was dropped. */
        void stale(String what);

        // Peripheral role. Server and advertiser callbacks come back with the epoch they were made in.

        /** Add one service to the platform's GATT server. null when accepted (serviceAdded follows). */
        String serviceAdd(int epoch, String uuid, boolean primary, List<Map<String, Object>> chars);

        void serviceRemove(String uuid);

        /** Start advertising as token {@code adv}. null when accepted (advertiseStarted follows). */
        String advertiseStart(int epoch, int adv, Map<String, Object> params);

        void advertiseStop(int adv);

        /**
         * Send one notification or indication packet to one central. null: handed over now; "pending":
         * notifySent follows; "full": the transmit queue is full, retry after notifyReady; else
         * "code message" (the packet settles at once).
         */
        String notify(int epoch, int packet, String central, String key, byte[] data, boolean indicate);

        /** Android: end a remote central's link (centralDisconnected follows). */
        void centralDrop(String central);

        /** Android keep-alive service: start (true) or stop hold generation {@code hold}. null, or why it did not start. */
        String keepAlive(boolean start, int hold);

        /** iOS: write the server snapshot (null: delete the file). */
        void persist(Map<String, Object> snapshot);
    }

    public static final int WRITE_MAX = 512;
    public static final int QUEUE_MAX = 64;
    public static final long OP_MS = 10000;
    public static final long CLOSE_MS = 2000;
    /** A connect's timeout when no call gave one (the bridge's {@code connect} default), in ms. */
    public static final int CONNECT_DEFAULT_MS = 10_000;
    public static final long FLUSH_MS = 50;
    public static final int BATCH_MAX = 100;
    public static final int JOURNAL_RECORDS = 2000;
    public static final int JOURNAL_BYTES = 1 << 20;
    public static final int DEVICES_MAX = 200;
    public static final int MTU_REQUEST = 517;

    final Port port;
    final boolean android;
    final String run;
    int epoch = 1;
    String adapter = "unknown";
    int nextGen, nextScan, nextOp, nextSeq, nextPending;
    public int staleDrops;
    final Map<String, Link> links = new LinkedHashMap<>();
    final Map<String, Closing> closing = new LinkedHashMap<>();
    /** Auto links ended by the adapter going off: re-linked when it comes back on. */
    final Map<String, Set<String>> autoWhenOn = new LinkedHashMap<>();
    int scan;
    int lastScan;
    final Map<String, Map<String, Object>> devices = new LinkedHashMap<>();
    final List<Map<String, Object>> pendingDevices = new ArrayList<>();
    final ArrayDeque<Map<String, Object>> journal = new ArrayDeque<>();
    int journalBytes;
    public int dropped;
    final List<Map<String, Object>> pendingValues = new ArrayList<>();
    boolean flushScheduled;

    static final class Link {
        final String id;
        final int gen;
        String state = "connecting";
        boolean auto;
        boolean background;
        int mtu = 23;
        int connectCall = -1;
        /** The token of the timer bounding an attempt no fresh connect started (restored or adopted). */
        int pendingTimer;
        boolean closed;
        final ArrayDeque<Op> queue = new ArrayDeque<>();
        Op inFlight;
        final Set<String> wanted = new LinkedHashSet<>();
        final Map<String, String> subs = new LinkedHashMap<>();
        int resubscribed, failed;

        Link(String id, int gen) {
            this.id = id;
            this.gen = gen;
        }
    }

    static final class Op {
        int op;
        final int call;
        final String kind;
        String key;
        String descriptor;
        byte[] data;
        int arg;
        int chunk, chunks;
        boolean internal;

        Op(int call, String kind) {
            this.call = call;
            this.kind = kind;
        }
    }

    static final class Closing {
        final int gen;
        int disconnectCall = -1;
        boolean reconnect;
        Set<String> wanted = new LinkedHashSet<>();
        Waiter waiter;

        Closing(int gen) {
            this.gen = gen;
        }
    }

    static final class Waiter {
        final int call, seconds, token;
        final boolean auto;

        Waiter(int call, boolean auto, int seconds, int token) {
            this.call = call;
            this.auto = auto;
            this.seconds = seconds;
            this.token = token;
        }
    }

    public BleCore(Port port, String platform, String run) {
        this.port = port;
        this.android = "android".equals(platform);
        this.run = run;
    }

    // ---- codec --------------------------------------------------------------------------------

    private static final char[] HEX = "0123456789abcdef".toCharArray();

    public static String hex(byte[] b) {
        char[] out = new char[b.length * 2];
        for (int i = 0; i < b.length; i++) {
            out[2 * i] = HEX[(b[i] >> 4) & 15];
            out[2 * i + 1] = HEX[b[i] & 15];
        }
        return new String(out);
    }

    private static int nibble(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    /** Hex digits only, even length; null otherwise. */
    public static byte[] fromHex(String s) {
        if (s == null || s.length() % 2 != 0) return null;
        byte[] out = new byte[s.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int hi = nibble(s.charAt(2 * i)), lo = nibble(s.charAt(2 * i + 1));
            if (hi < 0 || lo < 0) return null;
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    private static int sextet(char c) {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+' || c == '-') return 62;
        if (c == '/' || c == '_') return 63;
        return -1;
    }

    /** Standard or URL-safe base64, padding optional; null when malformed. */
    public static byte[] fromB64(String s) {
        if (s == null) return null;
        int end = s.length();
        int pad = 0;
        while (end > 0 && s.charAt(end - 1) == '=' && pad < 2) {
            end--;
            pad++;
        }
        if (pad > 0 && s.length() % 4 != 0) return null;
        if (end % 4 == 1) return null;
        byte[] out = new byte[end * 3 / 4];
        int acc = 0, bits = 0, n = 0;
        for (int i = 0; i < end; i++) {
            int v = sextet(s.charAt(i));
            if (v < 0) return null;
            acc = (acc << 6) | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                out[n++] = (byte) ((acc >> bits) & 0xff);
            }
        }
        // Leftover bits must be zero (canonical encoding).
        if ((acc & ((1 << bits) - 1)) != 0) return null;
        return out;
    }

    static final String BASE = "-0000-1000-8000-00805f9b34fb";

    private static boolean allHex(String s) {
        for (int i = 0; i < s.length(); i++) if (nibble(s.charAt(i)) < 0) return false;
        return true;
    }

    /** 16-bit, 32-bit or dashed 128-bit UUID, any case; lower-case 128-bit, or null. */
    public static String uuid(String s) {
        if (s == null) return null;
        String l = s.toLowerCase(Locale.ROOT);
        if (l.length() == 4 && allHex(l)) return "0000" + l + BASE;
        if (l.length() == 8 && allHex(l)) return l + BASE;
        if (l.length() != 36) return null;
        for (int i = 0; i < 36; i++) {
            char c = l.charAt(i);
            boolean dash = i == 8 || i == 13 || i == 18 || i == 23;
            if (dash ? c != '-' : nibble(c) < 0) return null;
        }
        return l;
    }

    /** Comma-separated UUIDs, at most 20; an empty or missing list is empty; null when malformed. */
    public static List<String> uuidList(String s) {
        List<String> out = new ArrayList<>();
        if (s == null || s.isEmpty()) return out;
        for (String part : s.split(",", -1)) {
            String u = uuid(part.trim());
            if (u == null) return null;
            if (!out.contains(u)) out.add(u);
        }
        return out.size() > 20 ? null : out;
    }

    /** iOS: a peripheral identifier (UUID). Android: a MAC in the form checkBluetoothAddress accepts. */
    public static boolean isId(String id, String platform) {
        if (id == null) return false;
        if ("android".equals(platform)) {
            if (id.length() != 17) return false;
            for (int i = 0; i < 17; i++) {
                char c = id.charAt(i);
                if (i % 3 == 2 ? c != ':' : !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return false;
            }
            return true;
        }
        return id.length() == 36 && uuid(id) != null;
    }

    /** Exactly one of hex and b64 decoded; null when none, both, or malformed. */
    public static byte[] bytes(String hex, String b64) {
        if ((hex == null) == (b64 == null)) return null;
        return hex != null ? fromHex(hex) : fromB64(b64);
    }

    /** The characteristic key used in replies, records and subscriptions. */
    public static String key(String service, int sn, String chr, int cn) {
        return service + "#" + sn + "/" + chr + "#" + cn;
    }

    /** Canonical JSON with keys in insertion order: the vector form, shared with the Swift twin. */
    public static String json(Object v) {
        StringBuilder b = new StringBuilder();
        json(b, v);
        return b.toString();
    }

    @SuppressWarnings("unchecked")
    private static void json(StringBuilder b, Object v) {
        if (v == null) {
            b.append("null");
        } else if (v instanceof Boolean || v instanceof Integer || v instanceof Long) {
            b.append(v);
        } else if (v instanceof String) {
            b.append('"');
            String s = (String) v;
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '"' || c == '\\') b.append('\\').append(c);
                else if (c < 0x20) b.append(String.format(Locale.ROOT, "\\u%04x", (int) c));
                else b.append(c);
            }
            b.append('"');
        } else if (v instanceof Map) {
            b.append('{');
            boolean first = true;
            for (Map.Entry<String, Object> e : ((Map<String, Object>) v).entrySet()) {
                if (!first) b.append(',');
                first = false;
                json(b, e.getKey());
                b.append(':');
                json(b, e.getValue());
            }
            b.append('}');
        } else if (v instanceof List) {
            b.append('[');
            boolean first = true;
            for (Object o : (List<Object>) v) {
                if (!first) b.append(',');
                first = false;
                json(b, o);
            }
            b.append(']');
        } else {
            throw new IllegalArgumentException("no JSON form for " + v.getClass().getName());
        }
    }

    /**
     * The platform's own error codes, by domain: the constant's name and a readable reason. From the
     * iOS SDK's CBError.h (CBErrorDomain) and the android-36 platform's BluetoothGatt constants; a
     * code with no public name (Android's 133, for one) keeps no name and its radio reason.
     */
    static final Map<String, Map<Integer, String[]>> ERROR_NAMES = new HashMap<>();
    static {
        Map<Integer, String[]> cb = new HashMap<>();
        cb.put(0, new String[] {"CBErrorUnknown", "unknown"});
        cb.put(1, new String[] {"CBErrorInvalidParameters", "invalid_parameters"});
        cb.put(2, new String[] {"CBErrorInvalidHandle", "invalid_handle"});
        cb.put(3, new String[] {"CBErrorNotConnected", "not_connected"});
        cb.put(4, new String[] {"CBErrorOutOfSpace", "out_of_space"});
        cb.put(5, new String[] {"CBErrorOperationCancelled", "operation_cancelled"});
        cb.put(6, new String[] {"CBErrorConnectionTimeout", "connection_timeout"});
        cb.put(7, new String[] {"CBErrorPeripheralDisconnected", "peripheral_disconnected"});
        cb.put(8, new String[] {"CBErrorUUIDNotAllowed", "uuid_not_allowed"});
        cb.put(9, new String[] {"CBErrorAlreadyAdvertising", "already_advertising"});
        cb.put(10, new String[] {"CBErrorConnectionFailed", "connection_failed"});
        cb.put(11, new String[] {"CBErrorConnectionLimitReached", "connection_limit_reached"});
        cb.put(12, new String[] {"CBErrorUnknownDevice", "unknown_device"});
        cb.put(13, new String[] {"CBErrorOperationNotSupported", "operation_not_supported"});
        cb.put(14, new String[] {"CBErrorPeerRemovedPairingInformation", "peer_removed_pairing_information"});
        cb.put(15, new String[] {"CBErrorEncryptionTimedOut", "encryption_timeout"});
        cb.put(16, new String[] {"CBErrorTooManyLEPairedDevices", "too_many_le_paired_devices"});
        cb.put(17, new String[] {"CBErrorLeGattExceededBackgroundNotificationLimit", "background_notification_limit_exceeded"});
        cb.put(18, new String[] {"CBErrorLeGattNearBackgroundNotificationLimit", "background_notification_limit_near"});
        ERROR_NAMES.put("CBErrorDomain", cb);
        Map<Integer, String[]> gatt = new HashMap<>();
        gatt.put(2, new String[] {"GATT_READ_NOT_PERMITTED", "read_not_permitted"});
        gatt.put(3, new String[] {"GATT_WRITE_NOT_PERMITTED", "write_not_permitted"});
        gatt.put(5, new String[] {"GATT_INSUFFICIENT_AUTHENTICATION", "insufficient_authentication"});
        gatt.put(6, new String[] {"GATT_REQUEST_NOT_SUPPORTED", "request_not_supported"});
        gatt.put(7, new String[] {"GATT_INVALID_OFFSET", "invalid_offset"});
        gatt.put(8, new String[] {"GATT_INSUFFICIENT_AUTHORIZATION", "insufficient_authorization"});
        gatt.put(13, new String[] {"GATT_INVALID_ATTRIBUTE_LENGTH", "invalid_attribute_length"});
        gatt.put(15, new String[] {"GATT_INSUFFICIENT_ENCRYPTION", "insufficient_encryption"});
        gatt.put(143, new String[] {"GATT_CONNECTION_CONGESTED", "connection_congested"});
        gatt.put(147, new String[] {"GATT_CONNECTION_TIMEOUT", "connection_timeout"});
        gatt.put(257, new String[] {"GATT_FAILURE", "failure"});
        ERROR_NAMES.put("android.bluetooth.BluetoothGatt", gatt);
    }

    /** The platform error of a link that went down, as the radio reports it, with the code's name. */
    public static Map<String, Object> platformError(String domain, int code, String message) {
        Map<String, Object> e = obj("domain", domain, "code", code, "message", message);
        Map<Integer, String[]> names = ERROR_NAMES.get(domain);
        String[] n = names == null ? null : names.get(code);
        if (n != null) e.put("name", n[0]);
        return e;
    }

    /** The link event's reason for an error: the code's readable reason, else the radio's. */
    static String errorReason(Map<String, Object> e, String fallback) {
        if (e == null || !(e.get("domain") instanceof String) || !(e.get("code") instanceof Integer)) return fallback;
        Map<Integer, String[]> names = ERROR_NAMES.get((String) e.get("domain"));
        String[] n = names == null ? null : names.get((Integer) e.get("code"));
        return n == null ? fallback : n[1];
    }

    /** " (domain code name: message)" for a failed call's message, or "" without an error. */
    static String errorText(Map<String, Object> e) {
        if (e == null) return "";
        String name = e.containsKey("name") ? " " + e.get("name") : "";
        return " (" + e.get("domain") + " " + e.get("code") + name + ": " + e.get("message") + ")";
    }

    public static Map<String, Object> obj(Object... kv) {
        Map<String, Object> m = new LinkedHashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put((String) kv[i], kv[i + 1]);
        return m;
    }

    // ---- Android permissions (the Swift twin has no counterpart: iOS has one authorization) --

    /** Install-time and runtime permissions a role needs on an API level; {install, runtime}. */
    public static List<List<String>> permissions(int sdk, String role, boolean neverForLocation) {
        List<String> install = new ArrayList<>(), runtime = new ArrayList<>();
        boolean scan = "scan".equals(role) || "central".equals(role);
        boolean connect = "connect".equals(role) || "central".equals(role) || "advertise".equals(role);
        boolean advertise = "advertise".equals(role);
        if (sdk >= 31) {
            if (scan) {
                runtime.add("android.permission.BLUETOOTH_SCAN");
                if (!neverForLocation) runtime.add("android.permission.ACCESS_FINE_LOCATION");
            }
            if (advertise) runtime.add("android.permission.BLUETOOTH_ADVERTISE");
            if (connect) runtime.add("android.permission.BLUETOOTH_CONNECT");
        } else {
            install.add("android.permission.BLUETOOTH");
            if (scan || advertise) install.add("android.permission.BLUETOOTH_ADMIN");
            if (scan) runtime.add("android.permission.ACCESS_FINE_LOCATION");
        }
        List<List<String>> out = new ArrayList<>();
        out.add(install);
        out.add(runtime);
        return out;
    }

    // ---- replies and records --------------------------------------------------------------------

    private void ok(int call, Map<String, Object> data) {
        if (call >= 0) port.reply(call, true, null, null, data);
    }

    private void fail(int call, String code, String message) {
        if (call >= 0) port.reply(call, false, code, message, null);
    }

    /** "code message" from a port refusal, split. */
    private void refused(int call, String err) {
        int sp = err.indexOf(' ');
        fail(call, sp < 0 ? err : err.substring(0, sp), sp < 0 ? "" : err.substring(sp + 1));
    }

    private void append(String event, Map<String, Object> data) {
        Map<String, Object> rec = obj("seq", ++nextSeq, "t", port.now(), "event", event, "data", data);
        int size = json(data).length() + 48;
        journal.addLast(rec);
        journalBytes += size;
        rec.put("_size", size);
        while (journal.size() > JOURNAL_RECORDS || journalBytes > JOURNAL_BYTES) {
            Map<String, Object> old = journal.removeFirst();
            journalBytes -= (Integer) old.get("_size");
            dropped++;
        }
    }

    /** An event that is also a journal record. */
    private void record(String event, Map<String, Object> data) {
        append(event, data);
        port.emit(event, data);
    }

    private void scheduleFlush() {
        if (flushScheduled) return;
        flushScheduled = true;
        port.timer("flush", 0, FLUSH_MS);
    }

    private void flush() {
        flushScheduled = false;
        if (!pendingDevices.isEmpty()) {
            List<Object> batch = new ArrayList<>(pendingDevices);
            pendingDevices.clear();
            record("device", obj("scan", lastScan, "devices", batch));
        }
        if (!pendingValues.isEmpty()) {
            int n = Math.min(BATCH_MAX, pendingValues.size());
            List<Object> batch = new ArrayList<>(pendingValues.subList(0, n));
            pendingValues.subList(0, n).clear();
            port.emit("value", obj("records", batch, "dropped", dropped));
            if (!pendingValues.isEmpty()) scheduleFlush();
        }
        if (!pendingRequests.isEmpty()) {
            int n = Math.min(BATCH_MAX, pendingRequests.size());
            List<Object> batch = new ArrayList<>(pendingRequests.subList(0, n));
            pendingRequests.subList(0, n).clear();
            port.emit("request", obj("records", batch, "dropped", dropped));
            if (!pendingRequests.isEmpty()) scheduleFlush();
        }
    }

    // ---- adapter --------------------------------------------------------------------------------

    public boolean on() {
        return "on".equals(adapter);
    }

    public int epoch() {
        return epoch;
    }

    /** The adapter or manager state changed (on, off, unauthorized, unsupported, resetting, unknown). */
    public void adapter(String state) {
        if (state.equals(adapter)) return;
        boolean wasOn = on();
        adapter = state;
        if (wasOn && !on()) {
            epoch++;
            if (scan != 0) endScan("adapter");
            serverDown();
            for (Link l : new ArrayList<>(links.values())) {
                if (l.auto) autoWhenOn.put(l.id, new LinkedHashSet<>(l.wanted));
                closeLink(l, "adapter", true);
                // The radio is off: every platform object of the old epoch is released, none waited for.
                port.release(l.id, l.gen);
            }
            for (Map.Entry<String, Closing> e : new ArrayList<>(closing.entrySet())) {
                Closing c = e.getValue();
                port.release(e.getKey(), c.gen);
                if (c.disconnectCall >= 0) ok(c.disconnectCall, obj("id", e.getKey(), "state", "disconnected", "confirmed", false));
                if (c.waiter != null) fail(c.waiter.call, "unavailable", "Bluetooth is " + state);
                if (c.reconnect) autoWhenOn.put(e.getKey(), c.wanted);
            }
            closing.clear();
        }
        record("adapter", obj("state", state, "epoch", epoch));
        if (!wasOn && on()) {
            for (Map.Entry<String, Set<String>> e : new ArrayList<>(autoWhenOn.entrySet())) {
                startLink(e.getKey(), true, -1, 0, true, e.getValue());
            }
            autoWhenOn.clear();
            serverUp();
        }
        updateHold();
    }

    /** Fields of the state reply that the core owns. */
    public Map<String, Object> stateFields() {
        return obj("scanning", scan != 0, "advertising", advertising, "links", links.size(), "centrals", centrals.size(),
                "keepAlive", keepAliveWanted, "epoch", epoch, "run", run);
    }

    // ---- scan -----------------------------------------------------------------------------------

    public void scanStart(int call, String servicesCsv, int seconds, boolean duplicates, String mode, boolean background) {
        List<String> services = uuidList(servicesCsv);
        if (services == null) {
            fail(call, "bad_value", "services must be up to 20 UUIDs");
            return;
        }
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        if (scan != 0) {
            fail(call, "busy", "a scan is already running");
            return;
        }
        if (background && services.isEmpty()) {
            fail(call, "filter_required", "a scan in the background needs a service filter");
            return;
        }
        int s = ++nextScan;
        String err = port.scanStart(s, services, duplicates, mode);
        if (err != null) {
            refused(call, err);
            return;
        }
        scan = s;
        lastScan = s;
        devices.clear();
        filtered = !services.isEmpty();
        if (seconds > 0) port.timer("scan", s, seconds * 1000L);
        ok(call, obj("scan", s));
    }

    boolean filtered;

    public void scanStop(int call) {
        if (scan == 0) {
            ok(call, obj("scan", lastScan, "stopped", false));
            return;
        }
        int s = scan;
        port.scanStop(s);
        endScan("stopped");
        ok(call, obj("scan", s, "stopped", true));
    }

    private void endScan(String reason) {
        int s = scan;
        scan = 0;
        flush();
        record("scan_end", obj("scan", s, "reason", reason));
    }

    /** One advertisement. {@code adv} holds name, rssi, connectable, services, manufacturer, serviceData, txPower. */
    public void device(int s, String id, Map<String, Object> adv) {
        if (s != scan || s == 0) {
            stale("device scan " + s);
            return;
        }
        Map<String, Object> d = devices.get(id);
        if (d == null) {
            if (devices.size() >= DEVICES_MAX) return;
            d = obj("id", id, "seen", 0);
            devices.put(id, d);
        }
        d.putAll(adv);
        d.put("seen", (Integer) d.get("seen") + 1);
        Map<String, Object> view = obj("id", id);
        view.putAll(adv);
        pendingDevices.add(view);
        scheduleFlush();
    }

    public void scanFailed(int s, String reason) {
        if (s != scan || s == 0) {
            stale("scan_failed " + s);
            return;
        }
        endScan("failed");
    }

    /** The app moved to (true) or out of the background. */
    public void background(boolean inBackground) {
        if (inBackground && scan != 0 && !filtered) {
            port.scanStop(scan);
            endScan("background");
        }
    }

    public void devices(int call) {
        List<Object> out = new ArrayList<>(devices.values());
        ok(call, obj("devices", out));
    }

    // ---- links ----------------------------------------------------------------------------------

    private boolean current(Link l, int gen) {
        return l != null && l.gen == gen && !l.closed;
    }

    private Link live(String id, int gen, String what) {
        Link l = links.get(id);
        if (!current(l, gen)) {
            stale(what + " " + id + " gen " + gen);
            return null;
        }
        return l;
    }

    private void stale(String what) {
        staleDrops++;
        port.stale(what);
    }

    private boolean checkId(int call, String id) {
        if (!isId(id, android ? "android" : "ios")) {
            fail(call, "bad_value", "id is not a device id of this platform");
            return false;
        }
        return true;
    }

    public void connect(int call, String id, boolean auto, int seconds) {
        if (!checkId(call, id)) return;
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        Link pending = links.get(id);
        if (pending != null) {
            // A pending attempt no call owns (restored by iOS, or an automatic reconnect) is
            // adopted: this call owns it from now on, with its own timeout, and the page's `auto` wins.
            if ("connecting".equals(pending.state) && pending.connectCall < 0 && !pending.closed) {
                pending.connectCall = call;
                pending.auto = auto;
                pending.background = false;
                boundPending(pending, seconds * 1000);
                return;
            }
            fail(call, "busy", "this device is linked or connecting");
            return;
        }
        if (closing.containsKey(id)) {
            // Rule 3: one live platform connection per device. Wait for the confirmed close.
            Closing c = closing.get(id);
            if (c.waiter != null || c.reconnect) {
                fail(call, "busy", "this device is still closing");
                return;
            }
            c.waiter = new Waiter(call, auto, seconds, ++nextOp);
            port.timer("wait", c.waiter.token, seconds * 1000L);
            return;
        }
        startLink(id, auto, call, seconds, false, new LinkedHashSet<>());
    }

    private void startLink(String id, boolean auto, int call, int seconds, boolean background, Set<String> wanted) {
        Link l = new Link(id, ++nextGen);
        l.auto = auto;
        l.background = background;
        l.connectCall = call;
        l.wanted.addAll(wanted);
        links.put(id, l);
        String err = port.connect(id, l.gen, auto, background);
        if (err != null) {
            links.remove(id);
            l.closed = true;
            refused(call, err);
            return;
        }
        if (call >= 0) port.timer("connect", l.gen, seconds * 1000L);
        if (background) record("link", obj("id", id, "link", l.gen, "state", "reconnecting", "reason", "auto"));
        updateHold();
    }

    /**
     * Bounds an attempt no fresh connect started: when the timer ends it still connecting, the
     * attempt is closed (the radio cancels it) and reported {@code timeout}.
     */
    private void boundPending(Link l, int ms) {
        l.pendingTimer = ++nextPending;
        port.timer("pending", l.pendingTimer, ms);
    }

    /** iOS state restoration: a peripheral the system kept for this app. Returns its gen. */
    public int restored(String id, boolean connected, List<String> subscribed) {
        return restored(id, connected, subscribed, false);
    }

    /**
     * iOS state restoration (the Swift twin's; Android has none). {@code pending}: handed back still
     * connecting; kept, bounded by the default connect timeout, unless a page connect adopts it.
     */
    public int restored(String id, boolean connected, List<String> subscribed, boolean pending) {
        Link l = new Link(id, ++nextGen);
        l.auto = true;
        l.background = true;
        for (String k : subscribed) {
            l.wanted.add(k);
            l.subs.put(k, "notify");
        }
        links.put(id, l);
        if (connected) {
            l.state = "connected";
        } else if (pending) {
            l.auto = false;
            boundPending(l, CONNECT_DEFAULT_MS);
        }
        return l.gen;
    }

    /** iOS state restoration finished: the {@code restored} event, kept in the journal like every event. */
    public void restoredEvent(Map<String, Object> data) {
        record("restored", data);
    }

    public void connected(String id, int gen, int mtu) {
        Link l = live(id, gen, "connected");
        if (l == null) return;
        if (!"connecting".equals(l.state)) return;
        l.state = "connected";
        l.mtu = mtu;
        if (android) {
            Op m = new Op(-1, "mtu");
            m.arg = MTU_REQUEST;
            m.internal = true;
            l.queue.add(m);
        }
        if (!l.wanted.isEmpty()) {
            Op d = new Op(-1, "discover");
            d.internal = true;
            l.queue.add(d);
            for (String k : l.wanted) {
                Op s = new Op(-1, "sub");
                s.key = k;
                s.internal = true;
                l.queue.add(s);
            }
        }
        Op ready = new Op(-1, "ready");
        ready.internal = true;
        l.queue.add(ready);
        pump(l);
    }

    /** The platform reported that attempt {@code gen} disconnected or failed to connect. */
    public void disconnected(String id, int gen, String reason) {
        disconnected(id, gen, reason, null);
    }

    /** {@code error}: the platform's own error, when it gave one ({domain, code, message}); it
     *  reaches the failed connect call's message and the {@code link} record unchanged. */
    public void disconnected(String id, int gen, String reason, Map<String, Object> error) {
        Link l = links.get(id);
        if (current(l, gen)) {
            closeLink(l, errorReason(error, reason), true, error);
            return;
        }
        Closing c = closing.get(id);
        if (c != null && c.gen == gen) {
            finishClosing(id, true);
            return;
        }
        stale("disconnected " + id + " gen " + gen);
    }

    public void disconnect(int call, String id) {
        if (!checkId(call, id)) return;
        Link l = links.get(id);
        if (l == null) {
            fail(call, "not_connected", "this device is not linked");
            return;
        }
        l.auto = false;
        l.wanted.clear();
        boolean confirmedNow = closeLink(l, "requested", false);
        if (confirmedNow) {
            ok(call, obj("id", id, "state", "disconnected", "confirmed", true));
        } else {
            closing.get(id).disconnectCall = call;
        }
    }

    /**
     * The one cleanup owner (rule 4). Runs to the end, idempotent. {@code down}: the platform already
     * reported the link down, so nothing is asked of it. Returns whether the close is confirmed now.
     */
    boolean closeLink(Link l, String reason, boolean down) {
        return closeLink(l, reason, down, null);
    }

    boolean closeLink(Link l, String reason, boolean down, Map<String, Object> error) {
        if (l.closed) return true;
        l.closed = true;
        List<Op> ops = new ArrayList<>();
        if (l.inFlight != null) ops.add(l.inFlight);
        ops.addAll(l.queue);
        l.inFlight = null;
        l.queue.clear();
        for (Op o : ops) {
            if (o.internal) continue;
            String msg = o.chunks > 1 ? "the link closed after " + o.chunk + " of " + o.chunks + " chunks were handed over"
                    : "the link closed while the operation waited";
            fail(o.call, "link_lost", msg);
        }
        if (l.connectCall >= 0) {
            String code = "timeout".equals(reason) ? "connect_timeout"
                    : "adapter".equals(reason) ? "unavailable"
                    : "requested".equals(reason) ? "link_lost" : "connect_failed";
            fail(l.connectCall, code, "the connection ended: " + reason + errorText(error));
            l.connectCall = -1;
        }
        if (links.get(l.id) == l) links.remove(l.id);
        boolean confirmed = down;
        if (!down) {
            confirmed = port.close(l.id, l.gen);
            if (!confirmed) {
                Closing c = new Closing(l.gen);
                closing.put(l.id, c);
                port.timer("close", l.gen, CLOSE_MS);
            }
        }
        Map<String, Object> rec = obj("id", l.id, "link", l.gen, "state", "disconnected", "reason", reason);
        if (error != null) rec.put("error", error);
        record("link", rec);
        if (l.auto && !"requested".equals(reason) && on()) {
            Closing c = closing.get(l.id);
            if (c != null) {
                c.reconnect = true;
                c.wanted = new LinkedHashSet<>(l.wanted);
            } else {
                startLink(l.id, true, -1, 0, true, l.wanted);
            }
        }
        updateHold();
        return confirmed;
    }

    private void finishClosing(String id, boolean confirmed) {
        Closing c = closing.remove(id);
        if (c == null) return;
        if (c.disconnectCall >= 0) ok(c.disconnectCall, obj("id", id, "state", "disconnected", "confirmed", confirmed));
        if (!on()) {
            if (c.waiter != null) fail(c.waiter.call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        if (c.reconnect) {
            startLink(id, true, -1, 0, true, c.wanted);
        } else if (c.waiter != null) {
            Waiter w = c.waiter;
            if (!port.isActive(w.call)) {
                fail(w.call, "timeout", "the route timed out while the previous connection closed");
                return;
            }
            startLink(id, w.auto, w.call, w.seconds, false, new LinkedHashSet<>());
        }
    }

    public void links(int call) {
        List<Object> out = new ArrayList<>();
        for (Link l : links.values()) {
            out.add(obj("id", l.id, "link", l.gen, "state", l.state, "auto", l.auto, "mtu", l.mtu,
                    "subscriptions", new ArrayList<Object>(l.subs.keySet())));
        }
        ok(call, obj("links", out));
    }

    // ---- operations -----------------------------------------------------------------------------

    private Link connectedLink(int call, String id) {
        if (!checkId(call, id)) return null;
        Link l = links.get(id);
        if (l == null || !"connected".equals(l.state)) {
            fail(call, "not_connected", "this device is not connected");
            return null;
        }
        return l;
    }

    private String target(int call, String service, int sn, String chr, int cn) {
        String s = uuid(service), c = uuid(chr);
        if (s == null || c == null) {
            fail(call, "bad_value", "service and char must be UUIDs");
            return null;
        }
        return key(s, sn, c, cn);
    }

    private void enqueue(int call, Link l, Op o) {
        if (l.queue.size() >= QUEUE_MAX) {
            fail(call, "busy", "too many operations are waiting on this link");
            return;
        }
        l.queue.add(o);
        pump(l);
    }

    public void discover(int call, String id) {
        Link l = connectedLink(call, id);
        if (l != null) enqueue(call, l, new Op(call, "discover"));
    }

    public void read(int call, String id, String service, int sn, String chr, int cn, String descriptor) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        String k = target(call, service, sn, chr, cn);
        if (k == null) return;
        String d = null;
        if (descriptor != null) {
            d = uuid(descriptor);
            if (d == null) {
                fail(call, "bad_value", "descriptor must be a UUID");
                return;
            }
        }
        Op o = new Op(call, "read");
        o.key = k;
        o.descriptor = d;
        enqueue(call, l, o);
    }

    public void write(int call, String id, String service, int sn, String chr, int cn, String descriptor,
                      String hexValue, String b64Value, boolean response) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        String k = target(call, service, sn, chr, cn);
        if (k == null) return;
        byte[] data = bytes(hexValue, b64Value);
        if (data == null) {
            fail(call, "bad_value", "give exactly one of hex and b64, well formed");
            return;
        }
        if (data.length > WRITE_MAX) {
            fail(call, "too_long", data.length + " bytes; at most " + WRITE_MAX);
            return;
        }
        String d = null;
        if (descriptor != null) {
            d = uuid(descriptor);
            if (d == null) {
                fail(call, "bad_value", "descriptor must be a UUID");
                return;
            }
            response = true;
        }
        Op o = new Op(call, response ? "write" : "wnr");
        o.key = k;
        o.descriptor = d;
        o.data = data;
        enqueue(call, l, o);
    }

    public void subscribe(int call, String id, String service, int sn, String chr, int cn, boolean on) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        String k = target(call, service, sn, chr, cn);
        if (k == null) return;
        Op o = new Op(call, on ? "sub" : "unsub");
        o.key = k;
        enqueue(call, l, o);
    }

    public void rssi(int call, String id) {
        Link l = connectedLink(call, id);
        if (l != null) enqueue(call, l, new Op(call, "rssi"));
    }

    public void mtu(int call, String id, int size) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        if (!android) {
            ok(call, mtuData(l, false));
            return;
        }
        Op o = new Op(call, "mtu");
        o.arg = size;
        enqueue(call, l, o);
    }

    private static Map<String, Object> mtuData(Link l, boolean requested) {
        return obj("mtu", l.mtu, "writeMax", WRITE_MAX, "writeNoResponseMax", l.mtu - 3, "requested", requested);
    }

    /** Hands the next operation to the platform when none is in flight. */
    private void pump(Link l) {
        while (l.inFlight == null && !l.queue.isEmpty() && !l.closed) {
            Op o = l.queue.poll();
            if (!o.internal && !port.isActive(o.call)) {
                // Rule 8: a route that timed out starts nothing new. Its reply is the bridge's to drop.
                fail(o.call, "timeout", "the route timed out before the operation started");
                continue;
            }
            if ("ready".equals(o.kind)) {
                ready(l);
                continue;
            }
            if ("wnr".equals(o.kind)) {
                int size = Math.max(1, l.mtu - 3);
                o.chunks = Math.max(1, (o.data.length + size - 1) / size);
                o.chunk = 0;
            }
            l.inFlight = o;
            send(l, o);
        }
    }

    private void send(Link l, Op o) {
        o.op = ++nextOp;
        byte[] data = o.data;
        if ("wnr".equals(o.kind)) {
            int size = Math.max(1, l.mtu - 3);
            int from = o.chunk * size, to = Math.min(o.data.length, from + size);
            data = java.util.Arrays.copyOfRange(o.data, from, to);
        }
        String err = port.op(l.id, l.gen, o.op, o.kind, o.key, o.descriptor, data, o.arg);
        if (err != null) {
            // Rule 6: a refusal settles the step at once and the queue moves on.
            l.inFlight = null;
            if (o.internal) {
                if ("sub".equals(o.kind)) l.failed++;
            } else {
                refused(o.call, err);
            }
            pump(l);
            return;
        }
        port.timer("op", o.op, OP_MS);
    }

    private void ready(Link l) {
        record("link", obj("id", l.id, "link", l.gen, "state", "connected", "reason", l.background ? "auto" : "requested",
                "resubscribed", l.resubscribed, "failed", l.failed));
        if (l.connectCall >= 0) {
            ok(l.connectCall, obj("id", l.id, "link", l.gen, "state", "connected", "mtu", l.mtu));
            l.connectCall = -1;
        }
    }

    /**
     * One GATT step settled. {@code code} null is success; {@code data} carries the platform's answer
     * (discover: services; read: hex; rssi: rssi; sub: mode).
     */
    public void opDone(String id, int gen, int op, String code, String message, Map<String, Object> data) {
        Link l = live(id, gen, "op");
        if (l == null) return;
        Op o = l.inFlight;
        if (o == null || o.op != op) {
            stale("op " + op);
            return;
        }
        if (code == null && "wnr".equals(o.kind) && o.chunk + 1 < o.chunks) {
            o.chunk++;
            send(l, o);
            return;
        }
        l.inFlight = null;
        settle(l, o, code, message, data);
        pump(l);
    }

    private void settle(Link l, Op o, String code, String message, Map<String, Object> data) {
        if (o.internal) {
            if ("sub".equals(o.kind)) {
                if (code == null) {
                    l.subs.put(o.key, data != null && data.get("mode") != null ? (String) data.get("mode") : "notify");
                    l.resubscribed++;
                } else {
                    l.failed++;
                }
            }
            return;
        }
        if (code != null) {
            fail(o.call, code, message);
            return;
        }
        switch (o.kind) {
            case "write":
                ok(o.call, obj("written", o.data.length, "chunks", 1));
                break;
            case "wnr":
                ok(o.call, obj("written", o.data.length, "chunks", o.chunks));
                break;
            case "sub": {
                String mode = data != null && data.get("mode") != null ? (String) data.get("mode") : "notify";
                l.subs.put(o.key, mode);
                l.wanted.add(o.key);
                ok(o.call, obj("subscribed", true, "mode", mode));
                break;
            }
            case "unsub":
                l.subs.remove(o.key);
                l.wanted.remove(o.key);
                ok(o.call, obj("subscribed", false));
                break;
            case "mtu":
                ok(o.call, mtuData(l, true));
                break;
            case "discover": {
                Map<String, Object> out = obj("id", l.id);
                if (data != null) out.putAll(data);
                ok(o.call, out);
                break;
            }
            default:
                ok(o.call, data == null ? obj() : data);
        }
    }

    /** The link's MTU changed. It completes the operation in flight only if that is the MTU request. */
    public void mtuChanged(String id, int gen, int mtu, boolean success) {
        Link l = live(id, gen, "mtu");
        if (l == null) return;
        if (success) l.mtu = mtu;
        Op o = l.inFlight;
        if (o != null && "mtu".equals(o.kind)) {
            l.inFlight = null;
            settle(l, o, null, null, null);
            pump(l);
        }
    }

    /**
     * A characteristic value arrived. {@code maybeRead}: the platform cannot say whether it answers a
     * read (iOS didUpdateValueFor); then a read of this characteristic in flight takes it.
     */
    public void value(String id, int gen, String key, String hexValue, boolean maybeRead) {
        Link l = live(id, gen, "value");
        if (l == null) return;
        Op o = l.inFlight;
        if (maybeRead && o != null && "read".equals(o.kind) && o.descriptor == null && key.equals(o.key)) {
            l.inFlight = null;
            settle(l, o, null, null, obj("hex", hexValue));
            pump(l);
            return;
        }
        String[] parts = key.split("[#/]");
        Map<String, Object> rec = obj("id", id, "link", gen, "service", parts[0], "char", parts[2],
                "service_n", Integer.parseInt(parts[1]), "char_n", Integer.parseInt(parts[3]), "hex", hexValue);
        append("value", rec);
        Map<String, Object> view = obj("seq", nextSeq, "t", journal.peekLast().get("t"));
        view.putAll(rec);
        pendingValues.add(view);
        scheduleFlush();
    }

    /** The remote GATT table changed: cached handles are gone, the next operation needs discover. */
    public void gattChanged(String id, int gen) {
        Link l = live(id, gen, "gatt_changed");
        if (l == null) return;
        record("gatt_changed", obj("id", id, "link", gen));
    }

    // ---- peripheral role: GATT server, advertising, keep-alive -------------------------------------

    public static final int CHARS_MAX = 16;
    public static final int SERVICES_MAX = 32;
    public static final int NOTIFY_MAX = 128;
    public static final long PERSIST_MS = 500;

    static final class Chr {
        final String uuid;
        final int n;
        final String flags;
        byte[] value;
        /** Subscribed centrals and their mode (notify or indicate), in subscription order. */
        final Map<String, String> subscribers = new LinkedHashMap<>();

        Chr(String uuid, int n, String flags, byte[] value) {
            this.uuid = uuid;
            this.n = n;
            this.flags = flags;
            this.value = value;
        }

        boolean has(char f) {
            return flags.indexOf(f) >= 0;
        }
    }

    static final class Service {
        final String uuid;
        final boolean primary;
        final List<Chr> chars;
        boolean added;
        int call = -1;
        int token;

        Service(String uuid, boolean primary, List<Chr> chars) {
            this.uuid = uuid;
            this.primary = primary;
            this.chars = chars;
        }
    }

    static final class Job {
        final int call;
        final int total;
        int left, sent;
        boolean started, failed;

        Job(int call, int total) {
            this.call = call;
            this.total = total;
            this.left = total;
        }
    }

    static final class Packet {
        final Job job;
        final String central, key;
        final byte[] data;
        final boolean indicate;
        int packet;

        Packet(Job job, String central, String key, byte[] data, boolean indicate) {
            this.job = job;
            this.central = central;
            this.key = key;
            this.data = data;
            this.indicate = indicate;
        }
    }

    final Map<String, Service> services = new LinkedHashMap<>();
    final ArrayDeque<Service> addQueue = new ArrayDeque<>();
    Service adding;
    /** Remote centrals by id, with their MTU. */
    final Map<String, Integer> centrals = new LinkedHashMap<>();
    /** Android prepared writes, by central and key, committed on execute. */
    final Map<String, byte[]> prepared = new LinkedHashMap<>();
    final ArrayDeque<Packet> notifyQueue = new ArrayDeque<>();
    Packet sending;
    boolean waitingReady;
    final List<Map<String, Object>> pendingRequests = new ArrayList<>();
    /** The page's standing advertising request (cleared by advertise_stop, elapsed or a failed start). */
    Map<String, Object> advWanted;
    long advUntil;
    int adv, nextAdv;
    boolean advertising;
    int advCall = -1;
    boolean keepAliveWanted, holdActive;
    int holdGen;
    String holdReason;
    boolean persistScheduled;

    /**
     * The {@code chars} grammar of service_add: characteristics separated by commas, each
     * {@code uuid~flags} or {@code uuid~flags~hex}. Flags r (read), w (write), c (write without
     * response), n (notify), i (indicate), R (read needs encryption, with r), W (write needs
     * encryption, with w or c). At most 16; equal UUIDs are numbered in order. Null when malformed.
     */
    public static List<Map<String, Object>> parseChars(String spec) {
        List<Map<String, Object>> out = new ArrayList<>();
        if (spec == null || spec.isEmpty()) return out;
        Map<String, Integer> seen = new LinkedHashMap<>();
        for (String part : spec.split(",", -1)) {
            String[] f = part.split("~", -1);
            if (f.length < 2 || f.length > 3) return null;
            String u = uuid(f[0].trim());
            String flags = f[1];
            if (u == null || flags.isEmpty()) return null;
            for (int i = 0; i < flags.length(); i++) {
                char c = flags.charAt(i);
                if ("rwcniRW".indexOf(c) < 0 || flags.indexOf(c) != i) return null;
            }
            boolean any = false;
            for (char c : new char[]{'r', 'w', 'c', 'n', 'i'}) any |= flags.indexOf(c) >= 0;
            if (!any) return null;
            if (flags.indexOf('R') >= 0 && flags.indexOf('r') < 0) return null;
            if (flags.indexOf('W') >= 0 && flags.indexOf('w') < 0 && flags.indexOf('c') < 0) return null;
            String start = null;
            if (f.length == 3) {
                byte[] b = fromHex(f[2]);
                if (b == null || f[2].isEmpty() || b.length > WRITE_MAX) return null;
                start = hex(b);
            }
            int n = seen.containsKey(u) ? seen.get(u) + 1 : 0;
            seen.put(u, n);
            Map<String, Object> c = obj("uuid", u, "n", n, "flags", flags);
            c.put("hex", start);
            out.add(c);
            if (out.size() > CHARS_MAX) return null;
        }
        return out;
    }

    /** Server and advertiser callbacks carry the epoch they were made in; an older one changes nothing. */
    private boolean serverCurrent(int e, String what) {
        if (e == epoch && on()) return true;
        stale(what + " epoch " + e);
        return false;
    }

    private Chr chr(String service, String chr, int cn) {
        String s = uuid(service), c = uuid(chr);
        Service svc = s == null ? null : services.get(s);
        if (svc == null || c == null) return null;
        for (Chr x : svc.chars) if (x.uuid.equals(c) && x.n == cn) return x;
        return null;
    }

    private Chr chrOf(String key) {
        String[] p = key.split("[#/]");
        Service svc = services.get(p[0]);
        if (svc == null) return null;
        int cn = Integer.parseInt(p[3]);
        for (Chr x : svc.chars) if (x.uuid.equals(p[2]) && x.n == cn) return x;
        return null;
    }

    private static String keyOf(Service s, Chr c) {
        return key(s.uuid, 0, c.uuid, c.n);
    }

    private static List<Object> properties(Chr c) {
        List<Object> out = new ArrayList<>();
        if (c.has('r')) out.add("read");
        if (c.has('c')) out.add("writeWithoutResponse");
        if (c.has('w')) out.add("write");
        if (c.has('n')) out.add("notify");
        if (c.has('i')) out.add("indicate");
        return out;
    }

    private static List<Map<String, Object>> charList(Service s) {
        List<Map<String, Object>> out = new ArrayList<>();
        for (Chr c : s.chars) {
            Map<String, Object> m = obj("uuid", c.uuid, "n", c.n, "flags", c.flags);
            m.put("hex", c.value == null ? null : hex(c.value));
            out.add(m);
        }
        return out;
    }

    private Map<String, Object> serviceView(Service s) {
        List<Object> chars = new ArrayList<>();
        for (Chr c : s.chars) {
            Map<String, Object> m = obj("uuid", c.uuid, "n", c.n, "properties", properties(c),
                    "subscribers", new ArrayList<Object>(c.subscribers.keySet()));
            m.put("hex", c.value == null ? null : hex(c.value));
            chars.add(m);
        }
        return obj("uuid", s.uuid, "primary", s.primary, "added", s.added, "characteristics", chars);
    }

    public void serviceAdd(int call, String uuidValue, boolean primary, String spec) {
        String u = uuid(uuidValue);
        List<Map<String, Object>> parsed = parseChars(spec);
        if (u == null || parsed == null) {
            fail(call, "bad_value", u == null ? "uuid must be a UUID" : "chars does not follow uuid~flags[~hex], at most 16");
            return;
        }
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        if (services.containsKey(u)) {
            fail(call, "bad_value", "this service is already in the table");
            return;
        }
        if (services.size() >= SERVICES_MAX) {
            fail(call, "busy", "the table holds " + SERVICES_MAX + " services");
            return;
        }
        List<Chr> chars = new ArrayList<>();
        for (Map<String, Object> c : parsed) {
            chars.add(new Chr((String) c.get("uuid"), (Integer) c.get("n"), (String) c.get("flags"),
                    c.get("hex") == null ? new byte[0] : fromHex((String) c.get("hex"))));
        }
        Service s = new Service(u, primary, chars);
        s.call = call;
        services.put(u, s);
        addQueue.add(s);
        pumpAdds();
    }

    /** Hands the next service to the platform; one add in flight, as Android requires. */
    private void pumpAdds() {
        while (adding == null && !addQueue.isEmpty()) {
            Service s = addQueue.poll();
            if (s.call >= 0 && !port.isActive(s.call)) {
                services.remove(s.uuid);
                fail(s.call, "timeout", "the route timed out before the service was added");
                continue;
            }
            String err = port.serviceAdd(epoch, s.uuid, s.primary, charList(s));
            if (err != null) {
                if (s.call >= 0) {
                    services.remove(s.uuid);
                    refused(s.call, err);
                    s.call = -1;
                }
                continue;
            }
            adding = s;
            s.token = ++nextOp;
            port.timer("service", s.token, OP_MS);
        }
    }

    /** The platform added (code null) or refused a service. */
    public void serviceAdded(int e, String uuidValue, String code) {
        if (!serverCurrent(e, "service_added")) return;
        Service s = adding;
        if (s == null || !s.uuid.equals(uuidValue)) {
            stale("service_added " + uuidValue);
            return;
        }
        adding = null;
        if (code == null) {
            s.added = true;
            if (s.call >= 0) ok(s.call, obj("uuid", s.uuid, "characteristics", serviceView(s).get("characteristics")));
            persistSoon();
        } else if (s.call >= 0) {
            services.remove(s.uuid);
            fail(s.call, "gatt_error", "the platform refused the service: " + code);
        }
        s.call = -1;
        pumpAdds();
    }

    public void serviceRemove(int call, String uuidValue) {
        List<Service> targets = new ArrayList<>();
        if (uuidValue == null) {
            targets.addAll(services.values());
        } else {
            String u = uuid(uuidValue);
            if (u == null) {
                fail(call, "bad_value", "uuid must be a UUID");
                return;
            }
            Service s = services.get(u);
            if (s == null) {
                fail(call, "not_found", "no such service in the table");
                return;
            }
            targets.add(s);
        }
        for (Service s : targets) {
            if (s == adding || s.call >= 0) {
                fail(call, "busy", "a service is still being added");
                return;
            }
        }
        List<Object> removed = new ArrayList<>();
        for (Service s : targets) {
            services.remove(s.uuid);
            addQueue.remove(s);
            if (s.added) port.serviceRemove(s.uuid);
            for (Chr c : s.chars) {
                for (String central : new ArrayList<>(c.subscribers.keySet())) dropSubscription(central, s.uuid, c);
            }
            removed.add(s.uuid);
        }
        persistSoon();
        ok(call, obj("removed", removed));
        pumpNotify();
    }

    public void services(int call) {
        List<Object> out = new ArrayList<>();
        for (Service s : services.values()) out.add(serviceView(s));
        ok(call, obj("services", out, "advertising", advertising));
    }

    public void valueSet(int call, String service, String chrUuid, int cn, String hexValue, String b64Value) {
        Chr c = chr(service, chrUuid, cn);
        if (c == null) {
            fail(call, "not_found", "no such characteristic in the table");
            return;
        }
        byte[] data = bytes(hexValue, b64Value);
        if (data == null) {
            fail(call, "bad_value", "give exactly one of hex and b64, well formed");
            return;
        }
        if (overMax(call, data)) return;
        c.value = data;
        persistSoon();
        ok(call, obj("bytes", data.length));
    }

    /** A server value is at most 512 bytes, as an attribute value is. */
    private boolean overMax(int call, byte[] data) {
        if (data.length <= WRITE_MAX) return false;
        fail(call, "too_long", data.length + " bytes; at most " + WRITE_MAX);
        return true;
    }

    public void notify(int call, String service, String chrUuid, int cn, String hexValue, String b64Value, String central) {
        Chr c = chr(service, chrUuid, cn);
        if (c == null) {
            fail(call, "not_found", "no such characteristic in the table");
            return;
        }
        byte[] data = bytes(hexValue, b64Value);
        if (data == null) {
            fail(call, "bad_value", "give exactly one of hex and b64, well formed");
            return;
        }
        if (overMax(call, data)) return;
        if (!c.has('n') && !c.has('i')) {
            fail(call, "not_permitted", "the characteristic neither notifies nor indicates");
            return;
        }
        List<String> to = new ArrayList<>();
        for (String x : c.subscribers.keySet()) if (central == null || central.equals(x)) to.add(x);
        if (to.isEmpty()) {
            fail(call, "no_subscribers", central == null ? "no central is subscribed" : "that central is not subscribed");
            return;
        }
        int room = Integer.MAX_VALUE;
        for (String x : to) room = Math.min(room, centrals.getOrDefault(x, 23) - 3);
        if (data.length > room) {
            fail(call, "too_long", data.length + " bytes; a subscriber's MTU allows " + room);
            return;
        }
        if (notifyQueue.size() + to.size() > NOTIFY_MAX) {
            fail(call, "busy", "too many notifications are waiting");
            return;
        }
        c.value = data;
        persistSoon();
        String key = null;
        for (Service s : services.values()) if (s.chars.contains(c)) key = keyOf(s, c);
        Job job = new Job(call, to.size());
        for (String x : to) notifyQueue.add(new Packet(job, x, key, data, "indicate".equals(c.subscribers.get(x))));
        pumpNotify();
    }

    private void resolve(Packet p, boolean sent) {
        Job j = p.job;
        j.left--;
        if (sent) j.sent++;
        if (j.left == 0 && !j.failed) ok(j.call, obj("sent", j.sent, "subscribers", j.total));
    }

    private void failJob(Job j, String code, String message) {
        if (j.failed) return;
        j.failed = true;
        fail(j.call, code, message);
    }

    /** Sends queued packets one at a time, in order. */
    private void pumpNotify() {
        while (sending == null && !waitingReady && !notifyQueue.isEmpty()) {
            Packet p = notifyQueue.peek();
            if (!p.job.failed && !p.job.started && !port.isActive(p.job.call)) {
                failJob(p.job, "timeout", "the route timed out before the notification was sent");
            }
            Chr c = p.job.failed ? null : chrOf(p.key);
            if (c == null || !c.subscribers.containsKey(p.central)) {
                notifyQueue.poll();
                resolve(p, false);
                continue;
            }
            p.job.started = true;
            p.packet = ++nextOp;
            String r = port.notify(epoch, p.packet, p.central, p.key, p.data, p.indicate);
            if ("full".equals(r)) {
                waitingReady = true;
                return;
            }
            notifyQueue.poll();
            if (r == null) {
                resolve(p, true);
            } else if ("pending".equals(r)) {
                sending = p;
                port.timer("notify", p.packet, OP_MS);
            } else {
                int sp = r.indexOf(' ');
                failJob(p.job, sp < 0 ? r : r.substring(0, sp), sp < 0 ? "" : r.substring(sp + 1));
                resolve(p, false);
            }
        }
    }

    /** Android onNotificationSent for packet {@code packet}. */
    public void notifySent(int e, int packet, String code) {
        if (!serverCurrent(e, "notify_sent")) return;
        Packet p = sending;
        if (p == null || p.packet != packet) {
            stale("notify_sent " + packet);
            return;
        }
        sending = null;
        if (code != null) failJob(p.job, "gatt_error", "the notification failed: " + code);
        resolve(p, code == null);
        pumpNotify();
    }

    /** iOS peripheralManagerIsReady(toUpdateSubscribers:): the transmit queue has room again. */
    public void notifyReady(int e) {
        if (!serverCurrent(e, "notify_ready")) return;
        if (!waitingReady) return;
        waitingReady = false;
        pumpNotify();
    }

    /** A remote central connected to this server (Android), or was first seen (iOS). */
    public void centralConnected(int e, String central, int mtu) {
        if (!serverCurrent(e, "central")) return;
        seen(central, mtu);
    }

    private void seen(String central, int mtu) {
        if (centrals.containsKey(central)) {
            if (mtu > 0) centrals.put(central, mtu);
            return;
        }
        centrals.put(central, mtu > 0 ? mtu : 23);
        record("central", obj("central", central, "state", "connected", "mtu", centrals.get(central)));
        updateHold();
    }

    public void centralMtu(int e, String central, int mtu) {
        if (!serverCurrent(e, "central_mtu")) return;
        if (centrals.containsKey(central)) centrals.put(central, mtu);
    }

    public void centralDisconnected(int e, String central) {
        if (!serverCurrent(e, "central_gone")) return;
        if (!centrals.containsKey(central)) {
            stale("central_gone " + central);
            return;
        }
        endCentral(central, "remote");
        pumpNotify();
    }

    private void endCentral(String central, String reason) {
        for (Service s : services.values()) for (Chr c : s.chars) c.subscribers.remove(central);
        prepared.keySet().removeIf(k -> k.startsWith(central + "|"));
        centrals.remove(central);
        record("central", obj("central", central, "state", "disconnected", "reason", reason));
        updateHold();
    }

    private void dropSubscription(String central, String service, Chr c) {
        c.subscribers.remove(central);
        record("central", obj("central", central, "state", "unsubscribed", "service", service, "char", c.uuid,
                "char_n", c.n));
        if (!android && !subscribed(central)) centrals.remove(central);
    }

    private boolean subscribed(String central) {
        for (Service s : services.values()) for (Chr c : s.chars) if (c.subscribers.containsKey(central)) return true;
        return false;
    }

    /**
     * A central subscribed ({@code mode} notify or indicate) or unsubscribed (null). Android: a CCCD
     * write the extension serves; iOS: didSubscribeTo or didUnsubscribeFrom. Returns the ATT outcome:
     * ok, not_found, not_permitted or stale.
     */
    public String subscription(int e, String central, int mtu, String key, String mode) {
        if (!serverCurrent(e, "subscription")) return "stale";
        Chr c = chrOf(key);
        if (c == null) return "not_found";
        if (mode != null && !c.has("indicate".equals(mode) ? 'i' : 'n')) return "not_permitted";
        seen(central, mtu);
        String service = key.substring(0, key.indexOf('#'));
        if (mode == null) {
            if (c.subscribers.containsKey(central)) dropSubscription(central, service, c);
        } else {
            c.subscribers.put(central, mode);
            record("central", obj("central", central, "state", "subscribed", "service", service, "char", c.uuid,
                    "char_n", c.n, "mode", mode, "mtu", centrals.get(central)));
        }
        pumpNotify();
        return "ok";
    }

    /** Android: the CCCD value this central reads back. */
    public String cccd(String central, String key) {
        Chr c = chrOf(key);
        String mode = c == null ? null : c.subscribers.get(central);
        return mode == null ? "0000" : "indicate".equals(mode) ? "0200" : "0100";
    }

    /** A read request, answered from the value store: {status, hex}. Status ok, not_found, not_permitted, invalid_offset, unlikely or stale. */
    public Map<String, Object> readRequest(int e, String central, int mtu, String key, int offset) {
        if (!serverCurrent(e, "read_request")) return obj("status", "stale");
        Chr c = chrOf(key);
        if (c == null) return obj("status", "not_found");
        seen(central, mtu);
        if (!c.has('r')) return obj("status", "not_permitted");
        if (c.value == null) return obj("status", "unlikely");
        if (offset > c.value.length) return obj("status", "invalid_offset");
        return obj("status", "ok", "hex", hex(java.util.Arrays.copyOfRange(c.value, offset, c.value.length)));
    }

    /**
     * Write requests of one central, applied all or none (iOS delivers a batch and answers it once;
     * Android passes one). Each is {key, offset, hex}. {@code prepare}: an Android prepared write,
     * buffered until executeWrite. Returns ok, not_found, not_permitted, invalid_offset,
     * invalid_length or stale.
     */
    public String writeRequests(int e, String central, int mtu, List<Map<String, Object>> reqs, boolean prepare) {
        if (!serverCurrent(e, "write_request")) return "stale";
        Map<String, byte[]> next = new LinkedHashMap<>();
        for (Map<String, Object> r : reqs) {
            String key = (String) r.get("key");
            Chr c = chrOf(key);
            if (c == null) return "not_found";
            if (!c.has('w') && !c.has('c')) return "not_permitted";
            byte[] data = fromHex((String) r.get("hex"));
            if (data == null) return "invalid_length";
            String slot = prepare ? central + "|" + key : key;
            byte[] base = next.containsKey(slot) ? next.get(slot)
                    : prepare ? prepared.getOrDefault(slot, new byte[0]) : c.value == null ? new byte[0] : c.value;
            int offset = (Integer) r.get("offset");
            if (offset > base.length) return "invalid_offset";
            if (offset + data.length > WRITE_MAX) return "invalid_length";
            byte[] v = java.util.Arrays.copyOf(base, offset + data.length);
            System.arraycopy(data, 0, v, offset, data.length);
            next.put(slot, v);
        }
        seen(central, mtu);
        for (Map.Entry<String, byte[]> x : next.entrySet()) {
            if (prepare) prepared.put(x.getKey(), x.getValue());
            else commit(central, x.getKey(), x.getValue());
        }
        return "ok";
    }

    /** Android onExecuteWrite: commit (true) or drop this central's prepared writes. */
    public String executeWrite(int e, String central, boolean execute) {
        if (!serverCurrent(e, "execute_write")) return "stale";
        for (String slot : new ArrayList<>(prepared.keySet())) {
            if (!slot.startsWith(central + "|")) continue;
            byte[] v = prepared.remove(slot);
            if (execute) commit(central, slot.substring(central.length() + 1), v);
        }
        return "ok";
    }

    private void commit(String central, String key, byte[] v) {
        Chr c = chrOf(key);
        if (c == null) return;
        c.value = v;
        String[] p = key.split("[#/]");
        Map<String, Object> rec = obj("central", central, "kind", "write", "service", p[0], "char", p[2],
                "char_n", Integer.parseInt(p[3]), "hex", hex(v));
        append("request", rec);
        Map<String, Object> view = obj("seq", nextSeq, "t", journal.peekLast().get("t"));
        view.putAll(rec);
        pendingRequests.add(view);
        scheduleFlush();
        persistSoon();
    }

    public void centrals(int call) {
        List<Object> out = new ArrayList<>();
        for (Map.Entry<String, Integer> x : centrals.entrySet()) {
            List<Object> subs = new ArrayList<>();
            for (Service s : services.values()) for (Chr c : s.chars) if (c.subscribers.containsKey(x.getKey())) subs.add(keyOf(s, c));
            out.add(obj("central", x.getKey(), "mtu", x.getValue(), "subscriptions", subs));
        }
        ok(call, obj("centrals", out));
    }

    public void centralDrop(int call, String central) {
        if (!android) {
            fail(call, "platform_limit", "iOS has no API to drop a remote central");
            return;
        }
        if (!isId(central, "android") || !centrals.containsKey(central)) {
            fail(call, "unknown_device", "that central is not connected");
            return;
        }
        port.centralDrop(central);
        ok(call, obj("dropped", true));
    }

    // ---- advertising ----------------------------------------------------------------------------

    public void advertiseStart(int call, String servicesCsv, String name, int manufacturerId, String manufacturerHex,
                               String serviceDataUuid, String serviceDataHex, boolean connectable, String mode, int seconds) {
        List<String> uuids = uuidList(servicesCsv);
        if (uuids == null) {
            fail(call, "bad_value", "services must be up to 20 UUIDs");
            return;
        }
        if ((manufacturerId < 0) != (manufacturerHex == null) || manufacturerId > 0xFFFF
                || (manufacturerHex != null && fromHex(manufacturerHex) == null)) {
            fail(call, "bad_value", "manufacturer_id (0 to 65535) and manufacturer_hex go together, as an id and hex bytes");
            return;
        }
        String sdUuid = serviceDataUuid == null ? null : uuid(serviceDataUuid);
        if ((serviceDataUuid == null) != (serviceDataHex == null) || (serviceDataUuid != null && sdUuid == null)
                || (serviceDataHex != null && fromHex(serviceDataHex) == null)) {
            fail(call, "bad_value", "service_data_uuid and service_data_hex go together, as a UUID and hex bytes");
            return;
        }
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        if (adv != 0) {
            fail(call, "busy", "advertising is already running");
            return;
        }
        Map<String, Object> p = obj("services", new ArrayList<Object>(uuids), "name", name);
        p.put("manufacturerId", manufacturerId < 0 ? null : manufacturerId);
        p.put("manufacturerHex", manufacturerHex == null ? null : manufacturerHex.toLowerCase(Locale.ROOT));
        p.put("serviceDataUuid", sdUuid);
        p.put("serviceDataHex", serviceDataHex == null ? null : serviceDataHex.toLowerCase(Locale.ROOT));
        p.put("connectable", connectable);
        p.put("mode", mode);
        p.put("seconds", seconds);
        advWanted = p;
        advUntil = 0;
        advCall = call;
        startAdvertising(seconds);
    }

    private void startAdvertising(int seconds) {
        int t = ++nextAdv;
        Map<String, Object> p = advWanted;
        p.put("seconds", seconds);
        String err = port.advertiseStart(epoch, t, p);
        if (err != null) {
            advWanted = null;
            if (advCall >= 0) refused(advCall, err);
            else record("advertise_end", obj("reason", "failed"));
            advCall = -1;
            return;
        }
        adv = t;
        port.timer("advertise_start", t, OP_MS);
    }

    /** What this platform really advertises of the request. */
    private Map<String, Object> applied(Map<String, Object> p) {
        Map<String, Object> a = obj();
        a.put("name", p.get("name") == null ? null : android ? "adapter" : "given");
        a.put("manufacturer", android && p.get("manufacturerId") != null);
        a.put("serviceData", android && p.get("serviceDataUuid") != null);
        a.put("connectable", android ? p.get("connectable") : Boolean.TRUE);
        a.put("mode", android ? p.get("mode") : null);
        return a;
    }

    public void advertiseStarted(int e, int t, String code) {
        if (!serverCurrent(e, "advertise_started")) return;
        if (t != adv || advertising) {
            stale("advertise_started " + t);
            return;
        }
        if (code != null) {
            adv = 0;
            advWanted = null;
            if (advCall >= 0) fail(advCall, "advertise_failed", code);
            else record("advertise_end", obj("reason", "failed"));
            advCall = -1;
            return;
        }
        if (advCall >= 0 && !port.isActive(advCall)) {
            // The page already has the timeout: what it asked for does not stay on.
            port.advertiseStop(t);
            adv = 0;
            advWanted = null;
            fail(advCall, "timeout", "advertising started after the route timed out");
            advCall = -1;
            return;
        }
        advertising = true;
        int seconds = (Integer) advWanted.get("seconds");
        if (advUntil == 0 && seconds > 0) advUntil = port.now() + seconds * 1000L;
        if (seconds > 0) port.timer("advertise", t, Math.max(0, advUntil - port.now()));
        if (advCall >= 0) ok(advCall, obj("advertising", true, "applied", applied(advWanted)));
        advCall = -1;
        updateHold();
        persistSoon();
    }

    public void advertiseStop(int call) {
        boolean was = advertising;
        if (adv != 0) port.advertiseStop(adv);
        if (advCall >= 0) fail(advCall, "advertise_failed", "advertise_stop came before the platform started it");
        advCall = -1;
        adv = 0;
        advertising = false;
        advWanted = null;
        if (was) record("advertise_end", obj("reason", "stopped"));
        updateHold();
        persistSoon();
        ok(call, obj("advertising", false));
    }

    // ---- adapter changes of the server ----------------------------------------------------------

    /** Bluetooth left on: the server's platform objects of the old epoch are gone. */
    private void serverDown() {
        if (adv != 0) {
            if (advertising) record("advertise_end", obj("reason", "adapter"));
            if (advCall >= 0) {
                fail(advCall, "unavailable", "Bluetooth is " + adapter);
                advWanted = null;
            }
            advCall = -1;
            adv = 0;
            advertising = false;
        }
        for (String central : new ArrayList<>(centrals.keySet())) endCentral(central, "adapter");
        prepared.clear();
        if (sending != null) failJob(sending.job, "unavailable", "Bluetooth is " + adapter);
        for (Packet p : notifyQueue) failJob(p.job, "unavailable", "Bluetooth is " + adapter);
        sending = null;
        notifyQueue.clear();
        waitingReady = false;
        List<Service> waiting = new ArrayList<>(addQueue);
        if (adding != null) waiting.add(0, adding);
        for (Service s : waiting) {
            if (s.call >= 0) {
                services.remove(s.uuid);
                fail(s.call, "unavailable", "Bluetooth is " + adapter);
                s.call = -1;
            }
        }
        adding = null;
        addQueue.clear();
        for (Service s : services.values()) s.added = false;
    }

    /** Bluetooth is on again: re-apply the page's services and advertising (inside its duration). */
    private void serverUp() {
        for (Service s : services.values()) if (!s.added && s != adding && !addQueue.contains(s)) addQueue.add(s);
        pumpAdds();
        if (advWanted != null && adv == 0) {
            int seconds = (Integer) advWanted.get("seconds");
            if (advUntil == 0 || seconds == 0) {
                startAdvertising(seconds);
            } else if (advUntil > port.now()) {
                startAdvertising((int) ((advUntil - port.now() + 999) / 1000));
            } else {
                advWanted = null;
                persistSoon();
            }
        }
    }

    // ---- keep-alive (Android foreground service) and the iOS server file ------------------------

    /** Links, remote centrals and advertising: what the Android keep-alive service holds the process for. */
    public int holdCount() {
        return links.size() + centrals.size() + (advertising ? 1 : 0);
    }

    private void updateHold() {
        if (!android) return;
        boolean want = keepAliveWanted && holdCount() > 0;
        if (want && !holdActive) {
            int g = ++holdGen;
            String err = port.keepAlive(true, g);
            holdActive = err == null;
            holdReason = err == null ? null : err.split(" ", 2)[0];
        } else if (!want && holdActive) {
            holdActive = false;
            holdReason = null;
            port.keepAlive(false, holdGen);
        }
    }

    /** BleLinkService.onStartCommand: whether start generation {@code g} is still the one to keep running. */
    public boolean holdCurrent(int g) {
        return holdActive && g == holdGen;
    }

    /** keep_alive. {@code backgroundModes}: iOS only, whether the build declares the Bluetooth background modes. */
    public void keepAlive(int call, boolean enabled, boolean backgroundModes) {
        keepAliveWanted = enabled;
        if (!android) {
            ok(call, obj("enabled", enabled, "active", backgroundModes, "reason", backgroundModes ? null : "no_background_mode"));
            return;
        }
        updateHold();
        String reason = !enabled || holdActive ? null : holdCount() == 0 ? "idle" : holdReason;
        ok(call, obj("enabled", enabled, "active", holdActive, "reason", reason));
    }

    /** iOS: the server table and advertising, written to ble-server.json (null: nothing to keep). */
    public Map<String, Object> serverSnapshot() {
        if (services.isEmpty() && advWanted == null) return null;
        List<Object> svcs = new ArrayList<>();
        for (Service s : services.values()) svcs.add(obj("uuid", s.uuid, "primary", s.primary, "chars", charList(s)));
        Map<String, Object> out = obj("services", svcs);
        out.put("advertise", advWanted);
        out.put("until", advUntil);
        return out;
    }

    private void persistSoon() {
        if (android || persistScheduled) return;
        persistScheduled = true;
        port.timer("persist", 0, PERSIST_MS);
    }

    // ---- timers ---------------------------------------------------------------------------------

    public void timer(String kind, int token) {
        switch (kind) {
            case "flush":
                flush();
                return;
            case "scan":
                if (token == scan && scan != 0) {
                    port.scanStop(scan);
                    endScan("elapsed");
                } else {
                    stale("scan timer " + token);
                }
                return;
            case "connect":
                for (Link l : links.values()) {
                    if (l.gen == token && !l.closed && "connecting".equals(l.state)) {
                        closeLink(l, "timeout", false);
                        return;
                    }
                }
                stale("connect timer " + token);
                return;
            case "pending":
                for (Link l : links.values()) {
                    if (l.pendingTimer == token && !l.closed && "connecting".equals(l.state)) {
                        closeLink(l, "timeout", false);
                        return;
                    }
                }
                stale("pending timer " + token);
                return;
            case "op":
                for (Link l : links.values()) {
                    if (l.inFlight != null && l.inFlight.op == token && !l.closed) {
                        Op o = l.inFlight;
                        l.inFlight = null;
                        settle(l, o, "gatt_error", "the operation got no answer in " + OP_MS / 1000 + " s", null);
                        closeLink(l, "op_timeout", false);
                        return;
                    }
                }
                stale("op timer " + token);
                return;
            case "close":
                for (Map.Entry<String, Closing> e : closing.entrySet()) {
                    if (e.getValue().gen == token) {
                        String id = e.getKey();
                        port.release(id, token);
                        finishClosing(id, false);
                        return;
                    }
                }
                stale("close timer " + token);
                return;
            case "wait":
                for (Map.Entry<String, Closing> e : closing.entrySet()) {
                    Waiter w = e.getValue().waiter;
                    if (w != null && w.token == token) {
                        e.getValue().waiter = null;
                        fail(w.call, "connect_timeout", "the previous connection did not close in time");
                        return;
                    }
                }
                stale("wait timer " + token);
                return;
            case "service":
                if (adding != null && adding.token == token) {
                    Service s = adding;
                    adding = null;
                    port.serviceRemove(s.uuid);
                    if (s.call >= 0) {
                        services.remove(s.uuid);
                        fail(s.call, "gatt_error", "the platform did not confirm the service in " + OP_MS / 1000 + " s");
                        s.call = -1;
                    }
                    pumpAdds();
                } else {
                    stale("service timer " + token);
                }
                return;
            case "notify":
                if (sending != null && sending.packet == token) {
                    Packet p = sending;
                    sending = null;
                    failJob(p.job, "gatt_error", "the notification got no answer in " + OP_MS / 1000 + " s");
                    resolve(p, false);
                    pumpNotify();
                } else {
                    stale("notify timer " + token);
                }
                return;
            case "advertise_start":
                if (token == adv && !advertising) {
                    port.advertiseStop(token);
                    adv = 0;
                    advWanted = null;
                    if (advCall >= 0) fail(advCall, "advertise_failed", "the platform did not answer the advertising start");
                    else record("advertise_end", obj("reason", "failed"));
                    advCall = -1;
                } else {
                    stale("advertise_start timer " + token);
                }
                return;
            case "advertise":
                if (token == adv && advertising) {
                    port.advertiseStop(token);
                    adv = 0;
                    advertising = false;
                    advWanted = null;
                    record("advertise_end", obj("reason", "elapsed"));
                    updateHold();
                    persistSoon();
                } else {
                    stale("advertise timer " + token);
                }
                return;
            case "persist":
                persistScheduled = false;
                port.persist(serverSnapshot());
                return;
            default:
                stale("timer " + kind);
        }
    }

    // ---- journal --------------------------------------------------------------------------------

    public void events(int call, int after, int max) {
        List<Object> out = new ArrayList<>();
        int next = after;
        for (Iterator<Map<String, Object>> it = journal.iterator(); it.hasNext() && out.size() < max; ) {
            Map<String, Object> r = it.next();
            int seq = (Integer) r.get("seq");
            if (seq <= after) continue;
            out.add(obj("seq", seq, "t", r.get("t"), "event", r.get("event"), "data", r.get("data")));
            next = seq;
        }
        ok(call, obj("records", out, "next", next, "dropped", dropped, "run", run));
    }
}
