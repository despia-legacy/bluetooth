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
        /**
         * Start a scan. {@code options}: the scan options the page gave beyond services, duplicates and
         * mode (keys as {@link #SCAN_OPTION_KEYS}); the radio applies what its platform offers.
         * Returns null when the platform accepted it, else "code message".
         */
        String scanStart(int scan, List<String> services, boolean duplicates, String mode, Map<String, Object> options);

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

        /**
         * The key of the first discovered characteristic of link {@code gen} that takes a write with
         * response ({@code withResponse}) or without one; null when none (the {@code raw} route).
         */
        String writable(String id, int gen, boolean withResponse);

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

        /**
         * Answer the central's request {@code request} (a read or write of a characteristic with flag
         * a) with an ATT outcome ({@link #ATT_STATUSES}), the offset and, for a read, the value. null when
         * handed over, else "code message".
         */
        String attRespond(int epoch, int request, String status, int offset, byte[] data);

        /** Publish an L2CAP channel as token {@code t}. null when accepted (l2capPublished follows). */
        String l2capPublish(int epoch, int t, boolean encrypted);

        void l2capUnpublish(int psm);

        /** Open channel {@code channel} to {@code id} on {@code psm}. null when accepted (l2capOpened follows). */
        String l2capOpen(int epoch, int channel, String id, int psm, boolean encrypted);

        /** Queue bytes on an open channel. null when accepted, else "code message". */
        String l2capSend(int channel, byte[] data);

        /** Close a channel or abandon its opening; no callback follows. */
        void l2capClose(int channel);

        /** Android: start advertising set {@code set}. null when accepted (advertiseSetStarted follows). */
        String advertiseSetStart(int epoch, int set, Map<String, Object> params);

        void advertiseSetStop(int set);

        // Android restoration: a scan the system keeps for the app when its process is gone, and the
        // companion device presence of devices the app associated (the iOS core asks only for the
        // associate family: AccessorySetupKit; it never asks for a wake scan or presence).

        /** Start the PendingIntent scan with these filters and mode. null when accepted, else "code message". */
        String wakeStart(Map<String, Object> filters, String mode);

        void wakeStop();

        /** Keep the running wake scan's filters across processes (null: none runs). */
        void wakeSave(Map<String, Object> filters);

        /** Show the system's companion device chooser as request {@code request}. null when shown (associated follows). */
        String associate(int request, Map<String, Object> params);

        /** The app's associations as records, or "code message". */
        Object associations();

        /** Remove association {@code association}. null when removed, else "code message". */
        String disassociate(int association);

        /** Start or stop observing the presence of association {@code association}. null when accepted, else "code message". */
        String presence(boolean start, int association);
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
    /** The disk-durable journal: the last seq handed out, records written since the last rewrite. */
    int persistedSeq, persistedSinceRewrite;
    /** The journal of the previous app process, read back from disk at launch. */
    String previousRun;
    List<Map<String, Object>> previousRecords = new ArrayList<>();
    int previousDropped;
    /** The last port refusal of a connect no call owned: code and message. */
    String[] lastRefusal = {"connect_failed", ""};

    static final class Link {
        final String id;
        final int gen;
        String state = "connecting";
        boolean auto;
        boolean background;
        int mtu = 23;
        int connectCall = -1;
        /**
         * A page {@code connect} with {@code seconds} 0: the attempt waits for the device without a time
         * limit (the route answered at once with {@code connecting}).
         */
        boolean unbounded;
        /** The system reconnects this link itself (the platform reported the drop with
         *  {@code reconnecting}). */
        boolean system;
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
        /** The {@code raw} route: the reply names the characteristic the radio chose. */
        boolean raw;

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
        return bytes(hex, b64, null);
    }

    /** Exactly one of hex, b64 and text (UTF-8) decoded; null when none, more than one, or malformed. */
    public static byte[] bytes(String hex, String b64, String text) {
        int given = (hex != null ? 1 : 0) + (b64 != null ? 1 : 0) + (text != null ? 1 : 0);
        if (given != 1) return null;
        if (text != null) return text.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        return hex != null ? fromHex(hex) : fromB64(b64);
    }

    /**
     * Comma-separated names (each 1 to 248 UTF-8 bytes, the GAP name limit), at most 10; empty when
     * missing; null when malformed.
     */
    public static List<String> nameList(String s) {
        List<String> out = new ArrayList<>();
        if (s == null || s.isEmpty()) return out;
        for (String n : s.split(",", -1)) {
            int len = n.getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
            if (len == 0 || len > 248) return null;
            if (!out.contains(n)) out.add(n);
        }
        return out.size() > 10 ? null : out;
    }

    /** PHY names of the {@code phy} route (1m, 2m, coded), comma-separated; null when malformed or empty. */
    public static List<String> phyList(String s) {
        if (s == null || s.isEmpty()) return null;
        List<String> out = new ArrayList<>();
        for (String p : s.split(",", -1)) {
            if (!"1m".equals(p) && !"2m".equals(p) && !"coded".equals(p)) return null;
            if (!out.contains(p)) out.add(p);
        }
        return out;
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

    public static final String BACKGROUND_LOCATION = "android.permission.ACCESS_BACKGROUND_LOCATION";

    /**
     * Install-time and runtime permissions a role needs on an API level; {install, runtime}. The role
     * {@code wake} (wake_start) is a scan that runs while the app has no process: on Android 10 and 11
     * (API 29 and 30) it also needs ACCESS_BACKGROUND_LOCATION (Android, "Bluetooth permissions": "If your
     * app supports a service and can run on Android 10 (API level 29) or Android 11, you must also declare
     * the ACCESS_BACKGROUND_LOCATION permission to discover Bluetooth devices", read 2026-11-26).
     */
    public static List<List<String>> permissions(int sdk, String role, boolean neverForLocation) {
        List<String> install = new ArrayList<>(), runtime = new ArrayList<>();
        boolean wake = "wake".equals(role);
        boolean scan = "scan".equals(role) || "central".equals(role) || wake;
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
            if (wake && (sdk == 29 || sdk == 30)) runtime.add(BACKGROUND_LOCATION);
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

    private static Map<String, Object> journalRecord(Map<String, Object> r) {
        return obj("seq", r.get("seq"), "t", r.get("t"), "event", r.get("event"), "data", r.get("data"));
    }

    /**
     * The disk-durable journal, asked by the extension on its own timer after events: the records
     * ({seq, t, event, data}) to append to this run's file since the last call, or, once the file holds
     * twice the window's record count, the whole window to replace it with ({@code rewrite}), so the
     * file stays bounded. Null when there is nothing new. Element 0: the records; element 1: rewrite.
     */
    public Object[] journalToPersist() {
        List<Map<String, Object>> out = new ArrayList<>();
        boolean rewrite = false;
        if (persistedSinceRewrite >= JOURNAL_RECORDS * 2) {
            rewrite = true;
            for (Map<String, Object> r : journal) out.add(journalRecord(r));
            persistedSinceRewrite = out.size();
        } else {
            for (Map<String, Object> r : journal) {
                if ((Integer) r.get("seq") > persistedSeq) out.add(journalRecord(r));
            }
            persistedSinceRewrite += out.size();
        }
        if (!journal.isEmpty()) persistedSeq = (Integer) journal.peekLast().get("seq");
        return out.isEmpty() && !rewrite ? null : new Object[]{out, rewrite};
    }

    /**
     * Launch: the previous process's journal as its file held it (records {seq, t, event, data},
     * oldest first). Only the newest JOURNAL_RECORDS are kept; {@code events} with {@code run} reads them.
     */
    public void loadPrevious(String run, List<Map<String, Object>> records) {
        previousRun = run;
        previousDropped = Math.max(0, records.size() - JOURNAL_RECORDS);
        previousRecords = new ArrayList<>(records.subList(previousDropped, records.size()));
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
        if (!pendingL2cap.isEmpty()) {
            int n = Math.min(BATCH_MAX, pendingL2cap.size());
            List<Object> batch = new ArrayList<>(pendingL2cap.subList(0, n));
            pendingL2cap.subList(0, n).clear();
            port.emit("l2cap_data", obj("records", batch, "dropped", dropped));
            if (!pendingL2cap.isEmpty()) scheduleFlush();
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
                "keepAlive", keepAliveWanted, "epoch", epoch, "run", run, "previousRun", previousRun);
    }

    // ---- scan -----------------------------------------------------------------------------------

    /** The scan options passed through to the radio, by route parameter name. */
    public static final List<String> SCAN_OPTION_KEYS =
            java.util.Arrays.asList("legacy", "phy", "report_delay", "callback_type", "match", "matches", "solicited");

    /** The scan's own filters, applied here on every platform: advertised names, and a manufacturer id with a data prefix. */
    List<String> scanNames = new ArrayList<>();
    int scanManufacturer = -1;
    byte[] scanManufacturerPrefix = new byte[0];

    /**
     * What this platform applies of the given scan options: Android's ScanSettings (legacy, phy,
     * report_delay, callback, match, matches); iOS's solicited service UUIDs. Names and the
     * manufacturer filter are the core's own, so they apply on both.
     */
    Map<String, Object> scanApplied(Map<String, Object> options, boolean names, boolean manufacturer) {
        Map<String, Object> out = obj();
        if (names) out.put("names", true);
        if (manufacturer) out.put("manufacturer", true);
        for (String k : options.keySet()) out.put(k, "solicited".equals(k) ? !android : android);
        return out;
    }

    public void scanStart(int call, String servicesCsv, int seconds, boolean duplicates, String mode, boolean background) {
        scanStart(call, servicesCsv, seconds, duplicates, mode, background, null, -1, null, obj());
    }

    public void scanStart(int call, String servicesCsv, int seconds, boolean duplicates, String mode, boolean background,
                          String namesCsv, int manufacturerId, String manufacturerHex, Map<String, Object> options) {
        List<String> services = uuidList(servicesCsv);
        if (services == null) {
            fail(call, "bad_value", "services must be up to 20 UUIDs");
            return;
        }
        List<String> names = nameList(namesCsv);
        if (names == null) {
            fail(call, "bad_value", "names must be up to 10 comma-separated names of 1 to 248 bytes");
            return;
        }
        byte[] prefix = manufacturerHex == null ? null : fromHex(manufacturerHex);
        if (manufacturerId > 0xFFFF || (manufacturerHex != null && (prefix == null || manufacturerId < 0))) {
            fail(call, "bad_value", "manufacturer_id is 0 to 65535; manufacturer_hex is hex bytes and needs manufacturer_id");
            return;
        }
        for (String k : options.keySet()) {
            if (!SCAN_OPTION_KEYS.contains(k)) {
                fail(call, "bad_value", "unknown scan option " + k + "; the options are " + String.join(", ", SCAN_OPTION_KEYS));
                return;
            }
        }
        if (options.get("solicited") instanceof String) {
            List<String> list = uuidList((String) options.get("solicited"));
            if (list == null) {
                fail(call, "bad_value", "solicited must be up to 20 UUIDs");
                return;
            }
            options.put("solicited", new ArrayList<Object>(list));
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
        // Set before the port call: the radio builds its platform filters from them.
        scanNames = names;
        scanManufacturer = manufacturerId;
        scanManufacturerPrefix = prefix == null ? new byte[0] : prefix;
        String err = port.scanStart(s, services, duplicates, mode, options);
        if (err != null) {
            refused(call, err);
            return;
        }
        scan = s;
        lastScan = s;
        devices.clear();
        filtered = !services.isEmpty();
        if (seconds > 0) port.timer("scan", s, seconds * 1000L);
        ok(call, obj("scan", s, "applied", scanApplied(options, !names.isEmpty(), manufacturerId >= 0)));
    }

    /** Whether an advertisement passes the scan's own name and manufacturer filters. */
    private boolean matches(Map<String, Object> adv) {
        if (!scanNames.isEmpty()) {
            Object n = adv.get("name");
            if (!(n instanceof String) || !scanNames.contains(n)) return false;
        }
        if (scanManufacturer >= 0) {
            Object list = adv.get("manufacturer");
            if (!(list instanceof List)) return false;
            for (Object m : (List<?>) list) {
                if (!(m instanceof Map)) continue;
                Map<?, ?> o = (Map<?, ?>) m;
                if (!(o.get("id") instanceof Integer) || (Integer) o.get("id") != scanManufacturer) continue;
                byte[] b = o.get("hex") instanceof String ? fromHex((String) o.get("hex")) : null;
                if (b == null || b.length < scanManufacturerPrefix.length) continue;
                boolean same = true;
                for (int i = 0; i < scanManufacturerPrefix.length; i++) same &= b[i] == scanManufacturerPrefix[i];
                if (same) return true;
            }
            return false;
        }
        return true;
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
        if (!matches(adv)) return;
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

    /**
     * {@code seconds} 0: the attempt waits for the device without a time limit (iOS keeps a pending
     * connection, Android connects with autoConnect); the route answers at once with
     * {@code connecting} and the {@code link} event reports the connection.
     */
    public void connect(int call, String id, boolean auto, int seconds) {
        if (!checkId(call, id)) return;
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        if (seconds == 0) {
            if (links.containsKey(id) || closing.containsKey(id)) {
                fail(call, "busy", "this device is linked, connecting or closing");
                return;
            }
            startLink(id, auto, -1, 0, true, new LinkedHashSet<>(), true);
            Link l = links.get(id);
            if (l == null) {
                fail(call, lastRefusal[0], lastRefusal[1]);
                return;
            }
            ok(call, obj("id", id, "link", l.gen, "state", "connecting", "mtu", l.mtu));
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
                pending.unbounded = false;
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
        startLink(id, auto, call, seconds, background, wanted, false);
    }

    private void startLink(String id, boolean auto, int call, int seconds, boolean background, Set<String> wanted,
                           boolean unbounded) {
        startLink(id, auto, call, seconds, background, wanted, unbounded, false);
    }

    private void startLink(String id, boolean auto, int call, int seconds, boolean background, Set<String> wanted,
                           boolean unbounded, boolean system) {
        Link l = new Link(id, ++nextGen);
        l.auto = auto;
        l.background = background;
        l.unbounded = unbounded;
        l.system = system;
        l.connectCall = call;
        l.wanted.addAll(wanted);
        links.put(id, l);
        String err = port.connect(id, l.gen, auto, background);
        if (err != null) {
            links.remove(id);
            l.closed = true;
            int sp = err.indexOf(' ');
            lastRefusal = new String[]{sp < 0 ? err : err.substring(0, sp), sp < 0 ? "" : err.substring(sp + 1)};
            refused(call, err);
            return;
        }
        if (call >= 0) port.timer("connect", l.gen, seconds * 1000L);
        if (unbounded) {
            record("link", obj("id", id, "link", l.gen, "state", "connecting", "reason", "requested"));
        } else if (background) {
            record("link", obj("id", id, "link", l.gen, "state", "reconnecting", "reason", system ? "system" : "auto"));
        }
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
        disconnected(id, gen, reason, error, false);
    }

    /** {@code reconnecting}: the platform is reconnecting the device itself (iOS 17
     *  {@code isReconnecting}); the link closes as any drop does and a new attempt waits for that
     *  reconnect, as an {@code auto} link's would, without making the link {@code auto}. */
    public void disconnected(String id, int gen, String reason, Map<String, Object> error, boolean reconnecting) {
        Link l = links.get(id);
        if (current(l, gen)) {
            closeLink(l, errorReason(error, reason), true, error, reconnecting);
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
        return closeLink(l, reason, down, error, false);
    }

    boolean closeLink(Link l, String reason, boolean down, Map<String, Object> error, boolean systemReconnect) {
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
        if ((l.auto || systemReconnect) && !"requested".equals(reason) && on()) {
            Closing c = closing.get(l.id);
            if (c != null) {
                c.reconnect = true;
                c.wanted = new LinkedHashSet<>(l.wanted);
            } else {
                startLink(l.id, l.auto, -1, 0, true, l.wanted, false, systemReconnect && !l.auto);
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
        write(call, id, service, sn, chr, cn, descriptor, hexValue, b64Value, response, null);
    }

    public void write(int call, String id, String service, int sn, String chr, int cn, String descriptor,
                      String hexValue, String b64Value, boolean response, String text) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        String k = target(call, service, sn, chr, cn);
        if (k == null) return;
        byte[] data = writeData(call, hexValue, b64Value, text);
        if (data == null) return;
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

    /** The bytes of a write (exactly one of hex, b64 and text), or null after failing the call. */
    private byte[] writeData(int call, String hexValue, String b64Value, String text) {
        byte[] data = bytes(hexValue, b64Value, text);
        if (data == null) {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed");
            return null;
        }
        if (data.length > WRITE_MAX) {
            fail(call, "too_long", data.length + " bytes; at most " + WRITE_MAX);
            return null;
        }
        return data;
    }

    /**
     * The {@code raw} route: bytes to the first discovered characteristic that takes the write (with
     * response by default). The reply names the characteristic.
     */
    public void raw(int call, String id, String hexValue, String b64Value, String text, boolean response) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        byte[] data = writeData(call, hexValue, b64Value, text);
        if (data == null) return;
        String k = port.writable(l.id, l.gen, response);
        if (k == null) {
            fail(call, "not_found", "no discovered characteristic takes a write " + (response ? "with" : "without")
                    + " response (run discover first)");
            return;
        }
        Op o = new Op(call, response ? "write" : "wnr");
        o.key = k;
        o.data = data;
        o.raw = true;
        enqueue(call, l, o);
    }

    /** Android requestConnectionPriority: {@code level} balanced, high, low_power or dck. */
    public void priority(int call, String id, String level) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        if (!android) {
            fail(call, "platform_limit", "iOS has no API to request a connection priority or interval; the system and the peripheral set it");
            return;
        }
        Op o = new Op(call, "priority");
        o.key = level;
        enqueue(call, l, o);
    }

    /** Android setPreferredPhy (tx and rx given, {@code coded} none, s2 or s8) or readPhy (neither given). */
    public void phy(int call, String id, String tx, String rx, String coded) {
        Link l = connectedLink(call, id);
        if (l == null) return;
        if (!android) {
            fail(call, "platform_limit", "iOS has no API to read or set the LE PHY; the system chooses it");
            return;
        }
        if (tx == null && rx == null) {
            enqueue(call, l, new Op(call, "phy_read"));
            return;
        }
        List<String> t = phyList(tx != null ? tx : rx), r = phyList(rx != null ? rx : tx);
        if (t == null || r == null) {
            fail(call, "bad_value", "tx and rx are comma-separated PHYs: 1m, 2m, coded");
            return;
        }
        Op o = new Op(call, "phy_set");
        o.key = String.join(",", t) + "/" + String.join(",", r) + "/" + coded;
        enqueue(call, l, o);
    }

    /** The link's PHY changed (Android onPhyUpdate). It completes a phy_set in flight; otherwise it is a {@code phy} event. */
    public void phyChanged(String id, int gen, String tx, String rx, String code) {
        Link l = live(id, gen, "phy");
        if (l == null) return;
        Op o = l.inFlight;
        if (o != null && "phy_set".equals(o.kind)) {
            l.inFlight = null;
            settle(l, o, code == null ? null : "gatt_error", code == null ? null : "the PHY update failed: " + code,
                    obj("tx", tx, "rx", rx));
            pump(l);
            return;
        }
        if (code == null) record("phy", obj("id", id, "link", gen, "tx", tx, "rx", rx));
    }

    /** An event the extension produces outside the core's state (bond changes, for one): kept in the journal like every event. */
    public void external(String event, Map<String, Object> data) {
        record(event, data);
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
        record("link", obj("id", l.id, "link", l.gen, "state", "connected", "reason", l.system ? "system" : l.background && !l.unbounded ? "auto" : "requested",
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
            case "wnr": {
                Map<String, Object> r = obj("written", o.data.length, "chunks", "wnr".equals(o.kind) ? o.chunks : 1);
                if (o.raw && o.key != null) {
                    String[] p = o.key.split("[#/]");
                    r.putAll(obj("service", p[0], "char", p[2], "service_n", Integer.parseInt(p[1]),
                            "char_n", Integer.parseInt(p[3]), "response", "write".equals(o.kind)));
                }
                ok(o.call, r);
                break;
            }
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
     * encryption, with w or c), a (the page answers its reads and writes: att_request and respond,
     * with r, w or c). At most 16; equal UUIDs are numbered in order. Null when malformed.
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
                if ("rwcniRWa".indexOf(c) < 0 || flags.indexOf(c) != i) return null;
            }
            boolean any = false;
            for (char c : new char[]{'r', 'w', 'c', 'n', 'i'}) any |= flags.indexOf(c) >= 0;
            if (!any) return null;
            if (flags.indexOf('R') >= 0 && flags.indexOf('r') < 0) return null;
            if (flags.indexOf('W') >= 0 && flags.indexOf('w') < 0 && flags.indexOf('c') < 0) return null;
            if (flags.indexOf('a') >= 0 && flags.indexOf('r') < 0 && flags.indexOf('w') < 0 && flags.indexOf('c') < 0) return null;
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
        valueSet(call, service, chrUuid, cn, hexValue, b64Value, null);
    }

    public void valueSet(int call, String service, String chrUuid, int cn, String hexValue, String b64Value, String text) {
        Chr c = chr(service, chrUuid, cn);
        if (c == null) {
            fail(call, "not_found", "no such characteristic in the table");
            return;
        }
        byte[] data = bytes(hexValue, b64Value, text);
        if (data == null) {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed");
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
        notify(call, service, chrUuid, cn, hexValue, b64Value, central, null);
    }

    public void notify(int call, String service, String chrUuid, int cn, String hexValue, String b64Value, String central,
                       String text) {
        Chr c = chr(service, chrUuid, cn);
        if (c == null) {
            fail(call, "not_found", "no such characteristic in the table");
            return;
        }
        byte[] data = bytes(hexValue, b64Value, text);
        if (data == null) {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed");
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
        dropRequests(central, reason);
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

    /**
     * A read request, answered from the value store: {status, hex}. Status ok, not_found, not_permitted,
     * invalid_offset, unlikely or stale; for a characteristic with flag a, pending and the request
     * number: the page answers it with respond (or the core answers unlikely after ATT_ANSWER_MS).
     */
    public Map<String, Object> readRequest(int e, String central, int mtu, String key, int offset) {
        if (!serverCurrent(e, "read_request")) return obj("status", "stale");
        Chr c = chrOf(key);
        if (c == null) return obj("status", "not_found");
        seen(central, mtu);
        if (!c.has('r')) return obj("status", "not_permitted");
        if (c.has('a')) {
            String[] p = key.split("[#/]");
            Map<String, Object> view = obj("kind", "read", "central", central, "service", p[0], "char", p[2],
                    "char_n", Integer.parseInt(p[3]), "offset", offset);
            return obj("status", "pending", "request", openRequest(e, central, "read", offset, view, new LinkedHashMap<>()));
        }
        if (c.value == null) return obj("status", "unlikely");
        if (offset > c.value.length) return obj("status", "invalid_offset");
        return obj("status", "ok", "hex", hex(java.util.Arrays.copyOfRange(c.value, offset, c.value.length)));
    }

    /**
     * Write requests of one central, applied all or none (iOS delivers a batch and answers it once;
     * Android passes one). Each is {key, offset, hex}. {@code prepare}: an Android prepared write,
     * buffered until executeWrite. A request may carry {@code response: false} (Android
     * responseNeeded false). Returns ok, not_found, not_permitted, invalid_offset, invalid_length or
     * stale; when the batch writes a characteristic with flag a and wants a response, "pending N":
     * the page answers request N with respond, for the whole batch.
     */
    public String writeRequests(int e, String central, int mtu, List<Map<String, Object>> reqs, boolean prepare) {
        if (!serverCurrent(e, "write_request")) return "stale";
        Map<String, byte[]> next = new LinkedHashMap<>();
        List<Object> asked = new ArrayList<>();
        boolean response = true;
        for (Map<String, Object> r : reqs) {
            String key = (String) r.get("key");
            Chr c = chrOf(key);
            if (c == null) return "not_found";
            if (!c.has('w') && !c.has('c')) return "not_permitted";
            byte[] data = fromHex((String) r.get("hex"));
            if (data == null) return "invalid_length";
            if (Boolean.FALSE.equals(r.get("response"))) response = false;
            if (c.has('a') && !prepare) {
                int offset = (Integer) r.get("offset");
                if (offset + data.length > WRITE_MAX) return "invalid_length";
                asked.add(writeView(key, offset, data));
                continue;
            }
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
        if (!asked.isEmpty()) {
            Map<String, Object> view = obj("kind", "write", "central", central, "writes", asked);
            if (response) return "pending " + openRequest(e, central, "write", 0, view, next);
            // No answer travels back to the central: the page gets the write, and nothing waits.
            Map<String, Object> rec = obj("request", null, "state", "unanswered");
            rec.putAll(view);
            rec.put("mtu", centrals.get(central));
            record("att_request", rec);
        }
        for (Map.Entry<String, byte[]> x : next.entrySet()) {
            if (prepare) prepared.put(x.getKey(), x.getValue());
            else commit(central, x.getKey(), x.getValue());
        }
        return "ok";
    }

    /**
     * Android onExecuteWrite: commit (true) or drop this central's prepared writes. When a prepared
     * characteristic has flag a, "pending N": the page answers the assembled values with respond.
     */
    public String executeWrite(int e, String central, boolean execute) {
        if (!serverCurrent(e, "execute_write")) return "stale";
        List<Object> asked = new ArrayList<>();
        Map<String, byte[]> commits = new LinkedHashMap<>();
        for (String slot : new ArrayList<>(prepared.keySet())) {
            if (!slot.startsWith(central + "|")) continue;
            byte[] v = prepared.remove(slot);
            if (!execute) continue;
            String key = slot.substring(central.length() + 1);
            Chr c = chrOf(key);
            if (c != null && c.has('a')) asked.add(writeView(key, 0, v));
            else commits.put(key, v);
        }
        if (!asked.isEmpty()) {
            return "pending " + openRequest(e, central, "write", 0, obj("kind", "write", "central", central, "writes", asked),
                    commits);
        }
        for (Map.Entry<String, byte[]> x : commits.entrySet()) commit(central, x.getKey(), x.getValue());
        return "ok";
    }

    // ---- page-answered requests (characteristics with flag a) ------------------------------------

    /**
     * How long a request waits for the page: under ATT's 30 s transaction timeout (Bluetooth Core
     * 5.4, Vol 3, Part F, 3.3.3), after which the central drops the link; the core answers unlikely first.
     */
    public static final long ATT_ANSWER_MS = 25_000;
    /** The ATT outcomes respond takes; each radio maps them to its platform's codes. */
    public static final List<String> ATT_STATUSES = java.util.Arrays.asList("ok", "not_permitted", "invalid_offset",
            "invalid_length", "insufficient_authentication", "insufficient_authorization", "insufficient_encryption",
            "not_supported", "insufficient_resources", "unlikely");

    static final class Req {
        final int id, epoch, offset;
        final String central, kind;
        /** Writes in the same batch to characteristics without flag a: committed when the page answers ok. */
        final Map<String, byte[]> commits;

        Req(int id, int epoch, String central, String kind, int offset, Map<String, byte[]> commits) {
            this.id = id;
            this.epoch = epoch;
            this.central = central;
            this.kind = kind;
            this.offset = offset;
            this.commits = commits;
        }
    }

    final Map<Integer, Req> requests = new LinkedHashMap<>();
    int nextReq;

    private static Map<String, Object> writeView(String key, int offset, byte[] data) {
        String[] p = key.split("[#/]");
        return obj("service", p[0], "char", p[2], "char_n", Integer.parseInt(p[3]), "offset", offset, "hex", hex(data));
    }

    private int openRequest(int e, String central, String kind, int offset, Map<String, Object> view, Map<String, byte[]> commits) {
        int id = ++nextReq;
        requests.put(id, new Req(id, e, central, kind, offset, commits));
        Map<String, Object> rec = obj("request", id, "state", "open");
        rec.putAll(view);
        rec.put("mtu", centrals.get(central));
        record("att_request", rec);
        port.timer("att", id, ATT_ANSWER_MS);
        return id;
    }

    /**
     * respond: the page's answer to request {@code request}. {@code status} null means ok; a read
     * answered ok carries exactly one of hex, b64 and text (the value from the request's offset);
     * {@code offset} below 0 means the request's own.
     */
    public void respond(int call, int request, String status, String hexValue, String b64Value, String text, int offset) {
        Req q = requests.get(request);
        if (q == null) {
            fail(call, "not_found", "no open request " + request + ": it was answered, it expired or its central left");
            return;
        }
        String st = status == null ? "ok" : status;
        if (!ATT_STATUSES.contains(st)) {
            fail(call, "bad_value", "status must be one of " + String.join(", ", ATT_STATUSES));
            return;
        }
        byte[] data = null;
        if ("read".equals(q.kind) && "ok".equals(st)) {
            data = bytes(hexValue, b64Value, text);
            if (data == null) {
                fail(call, "bad_value", "a read answered ok carries exactly one of hex, b64 and text, well formed");
                return;
            }
            if (WRITE_MAX < data.length) {
                fail(call, "too_long", data.length + " bytes; at most " + WRITE_MAX);
                return;
            }
        } else if (hexValue != null || b64Value != null || text != null) {
            fail(call, "bad_value", "only a read answered ok carries a value");
            return;
        }
        requests.remove(request);
        String err = port.attRespond(q.epoch, request, st, offset < 0 ? q.offset : offset, data);
        if (err != null) {
            refused(call, err);
            return;
        }
        if ("ok".equals(st)) for (Map.Entry<String, byte[]> x : q.commits.entrySet()) commit(q.central, x.getKey(), x.getValue());
        record("att_request", obj("request", request, "state", "answered", "status", st));
        ok(call, obj("request", request, "status", st, "bytes", data == null ? 0 : data.length));
    }

    /** The open requests of {@code central} end without an answer: the central left (or the adapter went off). */
    private void dropRequests(String central, String reason) {
        for (Iterator<Req> it = requests.values().iterator(); it.hasNext(); ) {
            Req q = it.next();
            if (!central.equals(q.central)) continue;
            it.remove();
            record("att_request", obj("request", q.id, "state", "dropped", "reason", reason));
        }
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
        advertiseStart(call, servicesCsv, name, manufacturerId, manufacturerHex, serviceDataUuid, serviceDataHex, connectable,
                mode, seconds, null, null);
    }

    /**
     * {@code txPower} (ultra_low, low, medium, high) and {@code includeTxPower}: Android's
     * AdvertiseSettings tx power level and AdvertiseData tx power field, kept only when given.
     */
    public void advertiseStart(int call, String servicesCsv, String name, int manufacturerId, String manufacturerHex,
                               String serviceDataUuid, String serviceDataHex, boolean connectable, String mode, int seconds,
                               String txPower, Boolean includeTxPower) {
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
        if (txPower != null) p.put("txPower", txPower);
        if (includeTxPower != null) p.put("includeTxPower", includeTxPower);
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
        if (p.get("txPower") != null) a.put("txPower", android ? p.get("txPower") : null);
        if (p.get("includeTxPower") != null) a.put("includeTxPower", android && Boolean.TRUE.equals(p.get("includeTxPower")));
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

    // ---- L2CAP connection-oriented channels -------------------------------------------------------

    /** Bytes in one l2cap_send: the bridge carries a string of at most 4096 characters (hex 2048 bytes). */
    public static final int L2CAP_SEND_MAX = 2048;
    static final String L2CAP_PSM = "psm must be an LE PSM, 1 to 255 (Bluetooth Core 5.4, Vol 3, Part A, 4.22)";

    static final class Channel {
        final int n, psm;
        final String role, peer;
        String state;
        int call = -1;

        Channel(int n, String role, String peer, int psm, String state) {
            this.n = n;
            this.role = role;
            this.peer = peer;
            this.psm = psm;
            this.state = state;
        }
    }

    final Map<Integer, Channel> channels = new LinkedHashMap<>();
    /** Publishes in flight, by token: {call, encrypted}. */
    final Map<Integer, Object[]> publishing = new LinkedHashMap<>();
    /** Published PSMs and whether each needs encryption. */
    final Map<Integer, Boolean> published = new LinkedHashMap<>();
    final List<Map<String, Object>> pendingL2cap = new ArrayList<>();
    int nextChannel, nextPublish;

    private Map<String, Object> channelView(Channel ch) {
        return obj("channel", ch.n, "state", ch.state, "role", ch.role, "peer", ch.peer, "psm", ch.psm);
    }

    /** l2cap_publish: the peripheral role's listening channel; the platform picks the PSM. */
    public void l2capPublish(int call, boolean encrypted) {
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        int t = ++nextPublish;
        String err = port.l2capPublish(epoch, t, encrypted);
        if (err != null) {
            refused(call, err);
            return;
        }
        publishing.put(t, new Object[]{call, encrypted});
        port.timer("l2cap_publish", t, OP_MS);
    }

    public void l2capPublished(int e, int t, int psm, String code) {
        if (!serverCurrent(e, "l2cap_published")) return;
        Object[] p = publishing.remove(t);
        if (p == null) {
            stale("l2cap_published " + t);
            return;
        }
        int call = (Integer) p[0];
        boolean encrypted = (Boolean) p[1];
        if (code != null) {
            fail(call, "l2cap_failed", "the platform did not publish the channel: " + code);
            return;
        }
        if (call >= 0 && !port.isActive(call)) {
            port.l2capUnpublish(psm);
            fail(call, "timeout", "the channel was published after the route timed out");
            return;
        }
        published.put(psm, encrypted);
        ok(call, obj("psm", psm, "encrypted", encrypted));
    }

    public void l2capUnpublish(int call, int psm) {
        if (!published.containsKey(psm)) {
            fail(call, "not_found", "no published channel on psm " + psm);
            return;
        }
        published.remove(psm);
        port.l2capUnpublish(psm);
        ok(call, obj("psm", psm, "published", false));
    }

    /** A central opened a channel to a published PSM. Returns the channel number, or -1 (the radio closes it). */
    public int l2capIncoming(int e, int psm, String peer) {
        if (!serverCurrent(e, "l2cap_incoming")) return -1;
        if (!published.containsKey(psm)) {
            stale("l2cap_incoming psm " + psm);
            return -1;
        }
        Channel ch = new Channel(++nextChannel, "peripheral", peer, psm, "open");
        channels.put(ch.n, ch);
        record("l2cap", channelView(ch));
        updateHold();
        return ch.n;
    }

    /** l2cap_open: the central role's channel to {@code id} on {@code psm}, within {@code seconds}. */
    public void l2capOpen(int call, String id, int psm, boolean encrypted, int seconds) {
        if (!isId(id, android ? "android" : "ios")) {
            fail(call, "bad_value", "id must be a device id from a scan or a link");
            return;
        }
        if (psm < 1 || psm > 255) {
            fail(call, "bad_value", L2CAP_PSM);
            return;
        }
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        Channel ch = new Channel(++nextChannel, "central", id, psm, "opening");
        String err = port.l2capOpen(epoch, ch.n, id, psm, encrypted);
        if (err != null) {
            refused(call, err);
            return;
        }
        ch.call = call;
        channels.put(ch.n, ch);
        port.timer("l2cap_open", ch.n, (seconds > 0 ? seconds : 10) * 1000L);
    }

    public void l2capOpened(int e, int n, String code) {
        if (!serverCurrent(e, "l2cap_opened")) return;
        Channel ch = channels.get(n);
        if (ch == null || !"opening".equals(ch.state)) {
            stale("l2cap_opened " + n);
            return;
        }
        int call = ch.call;
        ch.call = -1;
        if (code != null) {
            channels.remove(n);
            fail(call, "l2cap_failed", "the channel did not open: " + code);
            return;
        }
        if (call >= 0 && !port.isActive(call)) {
            channels.remove(n);
            port.l2capClose(n);
            fail(call, "timeout", "the channel opened after the route timed out");
            return;
        }
        ch.state = "open";
        record("l2cap", channelView(ch));
        updateHold();
        ok(call, obj("channel", n, "psm", ch.psm, "id", ch.peer));
    }

    public void l2capSend(int call, int n, String hexValue, String b64Value, String text) {
        Channel ch = channels.get(n);
        if (ch == null) {
            fail(call, "not_found", "no channel " + n);
            return;
        }
        if (!"open".equals(ch.state)) {
            fail(call, "not_connected", "channel " + n + " is not open yet");
            return;
        }
        byte[] data = bytes(hexValue, b64Value, text);
        if (data == null || data.length == 0) {
            fail(call, "bad_value", "give exactly one of hex, b64 and text, well formed and not empty");
            return;
        }
        if (data.length > L2CAP_SEND_MAX) {
            fail(call, "too_long", data.length + " bytes; at most " + L2CAP_SEND_MAX + " per call");
            return;
        }
        String err = port.l2capSend(n, data);
        if (err != null) {
            refused(call, err);
            return;
        }
        ok(call, obj("channel", n, "bytes", data.length));
    }

    /** Bytes arrived on channel {@code n}: one l2cap_data record, batched like values. */
    public void l2capData(int n, String hexValue) {
        Channel ch = channels.get(n);
        if (ch == null || !"open".equals(ch.state)) {
            stale("l2cap_data " + n);
            return;
        }
        Map<String, Object> rec = obj("channel", n, "hex", hexValue);
        append("l2cap_data", rec);
        Map<String, Object> view = obj("seq", nextSeq, "t", journal.peekLast().get("t"));
        view.putAll(rec);
        pendingL2cap.add(view);
        scheduleFlush();
    }

    /** The platform closed channel {@code n} (the peer, or an error {@code code}). */
    public void l2capClosed(int n, String code) {
        Channel ch = channels.remove(n);
        if (ch == null) {
            stale("l2cap_closed " + n);
            return;
        }
        if ("opening".equals(ch.state)) {
            fail(ch.call, "l2cap_failed", "the channel closed before it opened" + (code == null ? "" : ": " + code));
            return;
        }
        ch.state = "closed";
        Map<String, Object> rec = channelView(ch);
        rec.put("reason", code == null ? "remote" : "error");
        if (code != null) rec.put("error", code);
        record("l2cap", rec);
        updateHold();
    }

    public void l2capClose(int call, int n) {
        Channel ch = channels.remove(n);
        if (ch == null) {
            fail(call, "not_found", "no channel " + n);
            return;
        }
        port.l2capClose(n);
        if ("opening".equals(ch.state)) {
            fail(ch.call, "l2cap_failed", "l2cap_close came before the channel opened");
        } else {
            ch.state = "closed";
            Map<String, Object> rec = channelView(ch);
            rec.put("reason", "requested");
            record("l2cap", rec);
        }
        updateHold();
        ok(call, obj("channel", n, "state", "closed"));
    }

    public void l2capChannels(int call) {
        List<Object> list = new ArrayList<>();
        for (Channel ch : channels.values()) list.add(channelView(ch));
        List<Object> psms = new ArrayList<>();
        for (Map.Entry<Integer, Boolean> x : published.entrySet()) psms.add(obj("psm", x.getKey(), "encrypted", x.getValue()));
        ok(call, obj("channels", list, "published", psms));
    }

    private int openChannels() {
        int k = 0;
        for (Channel ch : channels.values()) if ("open".equals(ch.state)) k++;
        return k;
    }

    // ---- extended advertising sets (Android) ------------------------------------------------------

    static final String ADV_SET_LIMIT = "iOS advertises one legacy advertisement: CBPeripheralManager.startAdvertising "
            + "takes only a local name and service UUIDs; extended and periodic advertising sets are not in its API";

    static final class AdvSet {
        final int n;
        int call;
        boolean on;

        AdvSet(int n, int call) {
            this.n = n;
            this.call = call;
        }
    }

    final Map<Integer, AdvSet> sets = new LinkedHashMap<>();
    int nextSet;

    private static Object given(Map<String, Object> raw, String k, Object dflt) {
        Object v = raw.get(k);
        return v == null ? dflt : v;
    }

    /** The manufacturer and service data pairs of one AdvertiseData under {@code prefix}; a String is the error. */
    private static Object adData(Map<String, Object> raw, String prefix, boolean withName) {
        Map<String, Object> d = obj();
        if (withName) {
            List<String> uuids = uuidList((String) raw.get(prefix + "services"));
            if (uuids == null) return prefix + "services must be up to 20 UUIDs";
            d.put("services", new ArrayList<Object>(uuids));
            d.put("includeName", given(raw, prefix + "include_name", false));
        }
        Object mid = raw.get(prefix + "manufacturer_id");
        String mhex = (String) raw.get(prefix + "manufacturer_hex");
        if ((mid == null) != (mhex == null) || (mid != null && ((Integer) mid < 0 || (Integer) mid > 0xFFFF))
                || (mhex != null && fromHex(mhex) == null)) {
            return prefix + "manufacturer_id (0 to 65535) and " + prefix + "manufacturer_hex go together, as an id and hex bytes";
        }
        d.put("manufacturerId", mid);
        d.put("manufacturerHex", mhex == null ? null : mhex.toLowerCase(Locale.ROOT));
        String su = (String) raw.get(prefix + "service_data_uuid"), shex = (String) raw.get(prefix + "service_data_hex");
        String sdUuid = su == null ? null : uuid(su);
        if ((su == null) != (shex == null) || (su != null && sdUuid == null) || (shex != null && fromHex(shex) == null)) {
            return prefix + "service_data_uuid and " + prefix + "service_data_hex go together, as a UUID and hex bytes";
        }
        d.put("serviceDataUuid", sdUuid);
        d.put("serviceDataHex", shex == null ? null : shex.toLowerCase(Locale.ROOT));
        return d;
    }

    /**
     * The advertise_set_start parameters, checked by the rules of Android's AdvertisingSetParameters
     * and the Core specification; a String is the error, else the parameters for the radio.
     */
    @SuppressWarnings("unchecked")
    static Object advertiseSetParams(Map<String, Object> raw) {
        boolean legacy = (Boolean) given(raw, "legacy", false);
        boolean connectable = (Boolean) given(raw, "connectable", false);
        boolean scannable = (Boolean) given(raw, "scannable", false);
        boolean anonymous = (Boolean) given(raw, "anonymous", false);
        boolean includeTxPower = (Boolean) given(raw, "include_tx_power", false);
        String primary = (String) given(raw, "primary_phy", "1m"), secondary = (String) given(raw, "secondary_phy", "1m");
        if (legacy) {
            if (anonymous) return "a legacy advertisement cannot be anonymous";
            if (connectable && !scannable) return "a legacy advertisement cannot be connectable and not scannable";
            if (includeTxPower) return "a legacy advertisement cannot carry the TX power in its header";
            if (!"1m".equals(primary) || !"1m".equals(secondary)) return "a legacy advertisement uses the 1M PHY";
        } else {
            if (connectable && scannable) return "an extended advertisement cannot be both connectable and scannable";
            if (anonymous && connectable) return "an extended advertisement cannot be both connectable and anonymous";
        }
        boolean periodic = raw.get("periodic_interval_ms") != null;
        if (periodic && (legacy || connectable || scannable)) {
            return "periodic advertising needs an extended set that is neither connectable nor scannable";
        }
        if (!periodic && (raw.get("periodic_include_tx_power") != null || raw.get("periodic_manufacturer_id") != null
                || raw.get("periodic_manufacturer_hex") != null || raw.get("periodic_service_data_uuid") != null
                || raw.get("periodic_service_data_hex") != null)) {
            return "periodic data needs periodic_interval_ms";
        }
        boolean response = raw.get("response_services") != null || raw.get("response_include_name") != null
                || raw.get("response_manufacturer_id") != null || raw.get("response_manufacturer_hex") != null;
        if (response && !scannable) return "a scan response needs a scannable set";
        Object data = adData(raw, "", true);
        if (data instanceof String) return data;
        Map<String, Object> p = obj("legacy", legacy, "connectable", connectable, "scannable", scannable, "anonymous", anonymous,
                "includeTxPower", includeTxPower, "primaryPhy", primary, "secondaryPhy", secondary);
        p.put("intervalMs", raw.get("interval_ms"));
        p.put("txPowerDbm", raw.get("tx_power_dbm"));
        p.put("data", data);
        ((Map<String, Object>) data).put("txPowerLevel", given(raw, "tx_power_data", false));
        if (response) {
            Object r = adData(raw, "response_", true);
            if (r instanceof String) return r;
            p.put("response", r);
        } else {
            p.put("response", null);
        }
        if (periodic) {
            Object d = adData(raw, "periodic_", false);
            if (d instanceof String) return d;
            p.put("periodic", obj("intervalMs", raw.get("periodic_interval_ms"),
                    "includeTxPower", given(raw, "periodic_include_tx_power", false), "data", d));
        } else {
            p.put("periodic", null);
        }
        p.put("seconds", given(raw, "seconds", 0));
        p.put("maxEvents", given(raw, "max_events", 0));
        return p;
    }

    @SuppressWarnings("unchecked")
    public void advertiseSetStart(int call, Map<String, Object> raw) {
        if (!android) {
            fail(call, "platform_limit", ADV_SET_LIMIT);
            return;
        }
        Object p = advertiseSetParams(raw);
        if (p instanceof String) {
            fail(call, "bad_value", (String) p);
            return;
        }
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        AdvSet a = new AdvSet(++nextSet, call);
        String err = port.advertiseSetStart(epoch, a.n, (Map<String, Object>) p);
        if (err != null) {
            refused(call, err);
            return;
        }
        sets.put(a.n, a);
        port.timer("advertise_set", a.n, OP_MS);
    }

    /** The platform started set {@code n} (code null, with its TX power in dBm) or refused it. */
    public void advertiseSetStarted(int e, int n, int txPower, String code) {
        if (!serverCurrent(e, "advertise_set_started")) return;
        AdvSet a = sets.get(n);
        if (a == null || a.on) {
            stale("advertise_set_started " + n);
            return;
        }
        int call = a.call;
        a.call = -1;
        if (code != null) {
            sets.remove(n);
            fail(call, "advertise_failed", code);
            return;
        }
        if (call >= 0 && !port.isActive(call)) {
            sets.remove(n);
            port.advertiseSetStop(n);
            fail(call, "timeout", "the set started after the route timed out");
            return;
        }
        a.on = true;
        record("advertising_set", obj("set", n, "state", "started", "tx_power", txPower));
        updateHold();
        ok(call, obj("set", n, "tx_power", txPower));
    }

    /** The platform ended set {@code n} by itself (its duration or event count ran out). */
    public void advertiseSetStopped(int e, int n) {
        if (!serverCurrent(e, "advertise_set_stopped")) return;
        AdvSet a = sets.get(n);
        if (a == null || !a.on) {
            stale("advertise_set_stopped " + n);
            return;
        }
        sets.remove(n);
        record("advertising_set", obj("set", n, "state", "stopped", "reason", "elapsed"));
        updateHold();
    }

    public void advertiseSetStop(int call, int n) {
        AdvSet a = sets.remove(n);
        if (a == null) {
            fail(call, "not_found", "no advertising set " + n);
            return;
        }
        port.advertiseSetStop(n);
        if (!a.on) {
            fail(a.call, "advertise_failed", "advertise_set_stop came before the platform started the set");
        } else {
            record("advertising_set", obj("set", n, "state", "stopped", "reason", "requested"));
        }
        updateHold();
        ok(call, obj("set", n, "state", "stopped"));
    }

    private int setsOn() {
        int k = 0;
        for (AdvSet a : sets.values()) if (a.on) k++;
        return k;
    }

    // ---- Android restoration: wake scan and companion device presence -------------------------------

    static final String WAKE_LIMIT = "iOS has no scan that outlives the app: a scan_start with services continues in the "
            + "background and is restored after a relaunch (CBCentralManager state restoration)";
    static final String PRESENCE_LIMIT = "iOS has no API to observe a device's presence; a connect with no time limit "
            + "completes when the device comes in range, and state restoration relaunches the app for it";
    static final String MIGRATE_ANDROID = "migrate is AccessorySetupKit's migration of a device the app already uses; Android has no such step, "
            + "a device the app already connects to needs none";
    static final String ASSOCIATE_COMPANY_NEEDS_MORE = "a filter by manufacturer_id alone is not enough for the iOS accessory picker: add name or "
            + "manufacturer_hex (Apple, Discovering and configuring accessories)";
    static final String ASSOCIATE_IOS_ADDRESS = "iOS gives an app no Bluetooth address (AccessorySetupKit answers a "
            + "Bluetooth identifier); filter by services and name";

    /** The running wake scan's filters (kept on disk by the port), or null. */
    Map<String, Object> wake;
    /** The open associate request's call, or -1. */
    int associateCall = -1;
    int nextAssociate;
    final Set<Integer> observing = new LinkedHashSet<>();

    /** Launch: the wake scan a previous process started is still the system's (a PendingIntent scan outlives the process). */
    public void loadWake(Map<String, Object> filters) {
        wake = filters;
    }

    public boolean waking() {
        return wake != null;
    }

    /** Launch: the presence observations a previous process started stay the system's. */
    public void loadObserving(List<Integer> list) {
        observing.clear();
        if (list != null) observing.addAll(list);
    }

    public List<Integer> observingList() {
        return new ArrayList<>(observing);
    }

    public void wakeStart(int call, String servicesCsv, String namesCsv, int manufacturerId, String manufacturerHex, String mode) {
        if (!android) {
            fail(call, "platform_limit", WAKE_LIMIT);
            return;
        }
        List<String> services = uuidList(servicesCsv);
        if (services == null) {
            fail(call, "bad_value", "services must be up to 20 UUIDs");
            return;
        }
        List<String> names = nameList(namesCsv);
        if (names == null) {
            fail(call, "bad_value", "names must be up to 10 comma-separated names of 1 to 248 bytes");
            return;
        }
        byte[] prefix = manufacturerHex == null ? null : fromHex(manufacturerHex);
        if (manufacturerId > 0xFFFF || (manufacturerHex != null && (prefix == null || manufacturerId < 0))) {
            fail(call, "bad_value", "manufacturer_id is 0 to 65535; manufacturer_hex is hex bytes and needs manufacturer_id");
            return;
        }
        if (services.isEmpty() && names.isEmpty() && manufacturerId < 0) {
            fail(call, "filter_required", "a wake scan needs a service, name or manufacturer filter");
            return;
        }
        if (!on()) {
            fail(call, "unavailable", "Bluetooth is " + adapter);
            return;
        }
        if (wake != null) {
            fail(call, "busy", "a wake scan is already running; wake_stop ends it");
            return;
        }
        Map<String, Object> f = obj("services", new ArrayList<Object>(services), "names", new ArrayList<Object>(names));
        if (manufacturerId >= 0) {
            f.put("manufacturer_id", manufacturerId);
            f.put("manufacturer_hex", prefix == null ? "" : hex(prefix));
        }
        String m = mode == null ? "low_power" : mode;
        f.put("mode", m);
        String err = port.wakeStart(f, m);
        if (err != null) {
            refused(call, err);
            return;
        }
        wake = f;
        port.wakeSave(f);
        record("wake", obj("state", "started", "filters", f));
        ok(call, obj("state", "started", "filters", f));
    }

    public void wakeStop(int call) {
        if (!android) {
            fail(call, "platform_limit", WAKE_LIMIT);
            return;
        }
        if (wake == null) {
            ok(call, obj("state", "stopped", "stopped", false));
            return;
        }
        port.wakeStop();
        wake = null;
        port.wakeSave(null);
        record("wake", obj("state", "stopped", "reason", "requested"));
        ok(call, obj("state", "stopped", "stopped", true));
    }

    /**
     * The system delivered the wake scan's PendingIntent: {@code devices} (records with id and the
     * advertisement fields) or {@code error} (a ScanCallback SCAN_FAILED code, which ends the scan).
     */
    public void wakeDelivered(List<Map<String, Object>> devices, int error) {
        if (wake == null) {
            stale("wake delivery");
            return;
        }
        if (error > 0) {
            port.wakeStop();
            wake = null;
            port.wakeSave(null);
            record("wake", obj("state", "failed", "error", error));
            return;
        }
        List<Object> list = new ArrayList<>();
        for (Map<String, Object> d : devices) {
            if (list.size() >= DEVICES_MAX) break;
            list.add(d);
        }
        if (!list.isEmpty()) record("wake", obj("state", "results", "devices", list));
    }

    public void associate(int call, Map<String, Object> raw) {
        List<String> services = uuidList((String) raw.get("services"));
        if (services == null || services.size() > 1) {
            fail(call, "bad_value", "services is one service UUID");
            return;
        }
        // The manufacturer filter, as on scan_start and wake_start: an id (a Bluetooth company identifier), and
        // optionally hex bytes the advertised manufacturer data starts with.
        int manufacturerId = -1;
        if (raw.get("manufacturer_id") != null) {
            manufacturerId = raw.get("manufacturer_id") instanceof Number ? ((Number) raw.get("manufacturer_id")).intValue() : -2;
        }
        String manufacturerHex = raw.get("manufacturer_hex") instanceof String ? (String) raw.get("manufacturer_hex") : null;
        byte[] prefix = manufacturerHex == null ? null : fromHex(manufacturerHex);
        if (manufacturerId < -1 || manufacturerId > 0xFFFF || (manufacturerHex != null && (prefix == null || manufacturerId < 0))) {
            fail(call, "bad_value", "manufacturer_id is 0 to 65535; manufacturer_hex is hex bytes and needs manufacturer_id");
            return;
        }
        Object name = raw.get("name");
        String migrate = null;
        if (raw.get("migrate") != null) {
            if (android) {
                fail(call, "platform_limit", MIGRATE_ANDROID);
                return;
            }
            Object m = raw.get("migrate");
            if (!(m instanceof String) || !((String) m).matches("[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")) {
                fail(call, "bad_value", "migrate is the id of a device the app already uses, a UUID");
                return;
            }
            migrate = ((String) m).toUpperCase(java.util.Locale.ROOT);
        }
        // AccessorySetupKit filters by a service UUID or a company identifier (Apple, ASDiscoveryDescriptor:
        // "Provide at least one UUID or manufacturer ID to filter"), and its accessory has no address. Apple's
        // "Discovering and configuring accessories": a descriptor with a company identifier needs one more
        // accessory identifier (a name, or manufacturer data), or the app crashes.
        if (!android) {
            if (services.isEmpty() && manufacturerId < 0) {
                fail(call, "bad_value", "services is one service UUID or manufacturer_id is a company identifier: the iOS accessory picker filters by one of them");
                return;
            }
            if (services.isEmpty() && prefix == null && (!(name instanceof String) || ((String) name).isEmpty())) {
                fail(call, "bad_value", ASSOCIATE_COMPANY_NEEDS_MORE);
                return;
            }
            if (raw.get("address") != null) {
                fail(call, "bad_value", ASSOCIATE_IOS_ADDRESS);
                return;
            }
        }
        Object address = raw.get("address");
        if (address != null && !(address instanceof String && ((String) address).matches("[0-9A-F]{2}(:[0-9A-F]{2}){5}"))) {
            fail(call, "bad_value", "address is a Bluetooth address like 00:11:22:AA:BB:CC");
            return;
        }
        if (associateCall >= 0 && port.isActive(associateCall)) {
            fail(call, "busy", "the device chooser is already open");
            return;
        }
        Map<String, Object> p = obj("services", new ArrayList<Object>(services), "name", name, "address", address,
                "single", !Boolean.FALSE.equals(raw.get("single")),
                "manufacturerId", manufacturerId < 0 ? null : (Object) manufacturerId,
                "manufacturerHex", prefix == null ? null : hex(prefix),
                "migrate", migrate);
        int r = ++nextAssociate;
        String err = port.associate(r, p);
        if (err != null) {
            refused(call, err);
            return;
        }
        associateCall = call;
        assocRequest = r;
    }

    int assocRequest;

    /** The chooser of request {@code r} ended: {@code info} (association, address, name) or the refusal "code message". */
    public void associated(int r, Map<String, Object> info, String err) {
        if (r != assocRequest || associateCall < 0) {
            stale("associated " + r);
            return;
        }
        int call = associateCall;
        associateCall = -1;
        if (err != null) {
            refused(call, err);
            return;
        }
        ok(call, info);
    }

    public void associations(int call) {
        Object r = port.associations();
        if (r instanceof String) {
            refused(call, (String) r);
            return;
        }
        List<Object> list = new ArrayList<>();
        for (Object o : (List<?>) r) {
            if (o instanceof Map) {
                Map<String, Object> m = obj();
                m.putAll(castObj(o));
                Object a = m.get("association");
                m.put("observing", a instanceof Integer && observing.contains(a));
                list.add(m);
            }
        }
        ok(call, obj("associations", list));
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> castObj(Object o) {
        return (Map<String, Object>) o;
    }

    public void disassociate(int call, int association) {
        if (association <= 0) {
            fail(call, "bad_value", "association is the id associate or associations gave");
            return;
        }
        String err = port.disassociate(association);
        if (err != null) {
            refused(call, err);
            return;
        }
        observing.remove(association);
        ok(call, obj("association", association, "removed", true));
    }

    public void presence(int call, int association, boolean start) {
        if (!android) {
            fail(call, "platform_limit", PRESENCE_LIMIT);
            return;
        }
        if (association <= 0) {
            fail(call, "bad_value", "association is the id associate or associations gave");
            return;
        }
        if (!start && !observing.contains(association)) {
            ok(call, obj("association", association, "observing", false, "stopped", false));
            return;
        }
        String err = port.presence(start, association);
        if (err != null) {
            refused(call, err);
            return;
        }
        if (start) observing.add(association);
        else observing.remove(association);
        ok(call, start ? obj("association", association, "observing", true)
                : obj("association", association, "observing", false, "stopped", true));
    }

    /**
     * The system reported a presence change of an associated device (CompanionDeviceService, also when
     * it started the process for it): appeared, disappeared, connected or disconnected.
     */
    public void presenceEvent(int association, String address, String event) {
        if (association > 0) observing.add(association);
        record("presence", obj("association", association, "address", address, "event", event));
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
        for (Channel ch : new ArrayList<>(channels.values())) {
            channels.remove(ch.n);
            port.l2capClose(ch.n);
            if ("opening".equals(ch.state)) {
                fail(ch.call, "unavailable", "Bluetooth is " + adapter);
            } else {
                ch.state = "closed";
                Map<String, Object> rec = channelView(ch);
                rec.put("reason", "adapter");
                record("l2cap", rec);
            }
        }
        for (Object[] p : publishing.values()) fail((Integer) p[0], "unavailable", "Bluetooth is " + adapter);
        publishing.clear();
        for (Integer psm : published.keySet()) port.l2capUnpublish(psm);
        published.clear();
        for (AdvSet a : sets.values()) {
            if (a.on) record("advertising_set", obj("set", a.n, "state", "stopped", "reason", "adapter"));
            else fail(a.call, "unavailable", "Bluetooth is " + adapter);
        }
        sets.clear();
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

    /** Links, remote centrals, advertising, started sets and open channels: what the Android keep-alive service holds the process for. */
    public int holdCount() {
        return links.size() + centrals.size() + (advertising ? 1 : 0) + setsOn() + openChannels();
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
            case "att": {
                Req q = requests.remove(token);
                if (q == null) {
                    stale("att timer " + token);
                    return;
                }
                port.attRespond(q.epoch, token, "unlikely", q.offset, null);
                record("att_request", obj("request", token, "state", "expired", "status", "unlikely"));
                return;
            }
            case "l2cap_publish": {
                Object[] p = publishing.remove(token);
                if (p == null) {
                    stale("l2cap_publish timer " + token);
                    return;
                }
                fail((Integer) p[0], "l2cap_failed", "the platform did not answer the publish in " + OP_MS / 1000 + " s");
                return;
            }
            case "l2cap_open": {
                Channel ch = channels.get(token);
                if (ch == null || !"opening".equals(ch.state)) {
                    stale("l2cap_open timer " + token);
                    return;
                }
                channels.remove(token);
                port.l2capClose(token);
                fail(ch.call, "timeout", "the channel did not open in time");
                return;
            }
            case "advertise_set": {
                AdvSet a = sets.get(token);
                if (a == null || a.on) {
                    stale("advertise_set timer " + token);
                    return;
                }
                sets.remove(token);
                port.advertiseSetStop(token);
                fail(a.call, "advertise_failed", "the platform did not answer the set start");
                return;
            }
            default:
                stale("timer " + kind);
        }
    }

    // ---- journal --------------------------------------------------------------------------------

    public void events(int call, int after, int max) {
        events(call, after, max, null);
    }

    /**
     * {@code asked}: null or this run reads the live journal; the previous run's id reads the journal
     * the previous app process left on disk.
     */
    public void events(int call, int after, int max, String asked) {
        if (asked != null && !asked.equals(run)) {
            if (!asked.equals(previousRun)) {
                fail(call, "not_found", "no journal is kept for that run");
                return;
            }
            List<Object> out = new ArrayList<>();
            int next = after;
            for (Map<String, Object> r : previousRecords) {
                if (out.size() >= max) break;
                int seq = r.get("seq") instanceof Number ? ((Number) r.get("seq")).intValue() : 0;
                if (seq <= after) continue;
                out.add(r);
                next = seq;
            }
            ok(call, obj("records", out, "next", next, "dropped", previousDropped, "run", asked));
            return;
        }
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
