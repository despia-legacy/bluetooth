package despia.ext.ble;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattServer;
import android.bluetooth.BluetoothGattServerCallback;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.AdvertiseCallback;
import android.bluetooth.le.AdvertiseData;
import android.bluetooth.le.AdvertiseSettings;
import android.bluetooth.le.BluetoothLeAdvertiser;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.ParcelUuid;
import android.util.SparseArray;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * The Android Bluetooth stack behind {@link BleCore}: scanner, GATT client, GATT server, advertiser,
 * the keep-alive service start and the adapter receiver. It makes no decision of its own. Every
 * callback object is created per scan, connection attempt, server epoch or advertisement and holds
 * its token in a final field; every callback copies what it needs and
 * posts to the main thread before anything else, where the core decides whether the token is still
 * current. No method here calls the core synchronously from a port call.
 *
 * <p>Permissions are checked by {@link BleExtension} before any route reaches the core; the
 * {@code MissingPermission} suppressions below rely on that, and a revoked permission surfaces as a
 * {@link SecurityException}, which every entry point turns into a refusal.
 */
@SuppressLint("MissingPermission")
final class AndroidRadio {
    static final UUID CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

    private final Context app;
    private final Handler main;
    private final BleCore core;
    private BroadcastReceiver receiver;
    private ScanCallback scanCallback;
    private BluetoothLeScanner scanner;
    /** One session per connection attempt, by gen. */
    private final Map<Integer, Session> sessions = new HashMap<>();

    /** One connection attempt: its own GATT object and its own callback. */
    final class Session extends BluetoothGattCallback {
        final String id;
        final int gen;
        BluetoothGatt gatt;
        boolean connected;
        boolean closing;
        int pendingOp;
        String pendingKind;
        String pendingMode;

        Session(String id, int gen) {
            this.id = id;
            this.gen = gen;
        }

        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            main.post(() -> connectionState(this, status, newState));
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int mtu, int status) {
            main.post(() -> core.mtuChanged(id, gen, mtu, status == BluetoothGatt.GATT_SUCCESS));
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            main.post(() -> discovered(this, status));
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value, int status) {
            byte[] v = value == null ? new byte[0] : value.clone();
            main.post(() -> done(this, status, BleCore.obj("hex", BleCore.hex(v))));
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            // API 32 and below only; from API 33 the stack calls the form with the value.
            byte[] v = Build.VERSION.SDK_INT >= 33 ? null : copy(c.getValue());
            main.post(() -> {
                if (v != null) done(this, status, BleCore.obj("hex", BleCore.hex(v)));
            });
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            main.post(() -> done(this, status, null));
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] value) {
            byte[] v = value == null ? new byte[0] : value.clone();
            String k = keyOf(g, c);
            main.post(() -> core.value(id, gen, k, BleCore.hex(v), false));
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            byte[] v = Build.VERSION.SDK_INT >= 33 ? null : copy(c.getValue());
            String k = v == null ? null : keyOf(g, c);
            main.post(() -> {
                if (v != null) core.value(id, gen, k, BleCore.hex(v), false);
            });
        }

        @Override
        public void onDescriptorRead(BluetoothGatt g, BluetoothGattDescriptor d, int status, byte[] value) {
            byte[] v = value == null ? new byte[0] : value.clone();
            main.post(() -> done(this, status, BleCore.obj("hex", BleCore.hex(v))));
        }

        @Override
        @SuppressWarnings("deprecation")
        public void onDescriptorRead(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
            byte[] v = Build.VERSION.SDK_INT >= 33 ? null : copy(d.getValue());
            main.post(() -> {
                if (v != null) done(this, status, BleCore.obj("hex", BleCore.hex(v)));
            });
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor d, int status) {
            main.post(() -> done(this, status, pendingMode == null ? null : BleCore.obj("mode", pendingMode)));
        }

        @Override
        public void onReadRemoteRssi(BluetoothGatt g, int rssi, int status) {
            main.post(() -> done(this, status, BleCore.obj("rssi", rssi)));
        }

        @Override
        public void onServiceChanged(BluetoothGatt g) {
            main.post(() -> core.gattChanged(id, gen));
        }
    }

    AndroidRadio(Context app, Handler main, BleCore core) {
        this.app = app;
        this.main = main;
        this.core = core;
        // The keep-alive service asks this core whether its start is still current; nothing starts here.
        BleLinkService.core = core;
    }

    private static byte[] copy(byte[] v) {
        return v == null ? new byte[0] : v.clone();
    }

    private BluetoothAdapter adapter() {
        BluetoothManager m = (BluetoothManager) app.getSystemService(Context.BLUETOOTH_SERVICE);
        return m == null ? null : m.getAdapter();
    }

    /** on, off or unsupported. */
    String adapterState() {
        BluetoothAdapter a = adapter();
        if (a == null) return "unsupported";
        return a.isEnabled() ? "on" : "off";
    }

    /** Starts listening for adapter changes; called on the first route, never at launch. */
    void start() {
        if (receiver != null) return;
        receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                int s = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR);
                String state = s == BluetoothAdapter.STATE_ON ? "on" : "off";
                main.post(() -> adapterChanged(state));
            }
        };
        IntentFilter f = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED);
        } else {
            app.registerReceiver(receiver, f);
        }
    }

    /** Bluetooth off ends the server and the advertisements of the current epoch, then the core hears it. */
    private void adapterChanged(String state) {
        if (!"on".equals(state)) {
            closeServer();
            advertisers.clear();
        }
        core.adapter(state);
    }

    // ---- scan -----------------------------------------------------------------------------------

    String scanStart(int scan, List<String> services, boolean duplicates, String mode) {
        BluetoothAdapter a = adapter();
        BluetoothLeScanner s = a == null || !a.isEnabled() ? null : a.getBluetoothLeScanner();
        if (s == null) return "unavailable Bluetooth is " + adapterState();
        List<ScanFilter> filters = new ArrayList<>();
        for (String u : services) {
            filters.add(new ScanFilter.Builder().setServiceUuid(ParcelUuid.fromString(u)).build());
        }
        int m = "low_power".equals(mode) ? ScanSettings.SCAN_MODE_LOW_POWER
                : "low_latency".equals(mode) ? ScanSettings.SCAN_MODE_LOW_LATENCY : ScanSettings.SCAN_MODE_BALANCED;
        ScanSettings settings = new ScanSettings.Builder().setScanMode(m).build();
        Set<String> seen = Collections.synchronizedSet(new HashSet<>());
        ScanCallback cb = new ScanCallback() {
            @Override
            public void onScanResult(int callbackType, ScanResult r) {
                String id = r.getDevice().getAddress();
                boolean first = seen.add(id);
                Map<String, Object> adv = duplicates || first ? advertisement(r) : null;
                main.post(() -> {
                    if (adv != null) core.device(scan, id, adv);
                });
            }

            @Override
            public void onBatchScanResults(List<ScanResult> results) {
                List<Object[]> batch = new ArrayList<>();
                for (ScanResult r : results) {
                    String id = r.getDevice().getAddress();
                    if (seen.add(id) || duplicates) batch.add(new Object[]{id, advertisement(r)});
                }
                main.post(() -> {
                    for (Object[] e : batch) core.device(scan, (String) e[0], castMap(e[1]));
                });
            }

            @Override
            public void onScanFailed(int errorCode) {
                main.post(() -> core.scanFailed(scan, "error " + errorCode));
            }
        };
        try {
            s.startScan(filters.isEmpty() ? null : filters, settings, cb);
        } catch (RuntimeException e) {
            // SecurityException (a permission revoked meanwhile) or IllegalStateException (Bluetooth off).
            return "scan_failed the scan could not start (" + e.getClass().getSimpleName() + ")";
        }
        scanner = s;
        scanCallback = cb;
        return null;
    }

    @SuppressWarnings("unchecked")
    private static Map<String, Object> castMap(Object o) {
        return (Map<String, Object>) o;
    }

    void scanStop(int scan) {
        ScanCallback cb = scanCallback;
        scanCallback = null;
        if (cb == null || scanner == null) return;
        try {
            scanner.stopScan(cb);
        } catch (RuntimeException ignored) {
            // Bluetooth turned off meanwhile: nothing left to stop.
        }
    }

    /** Every advertisement field the platform reports, in the core's record form. */
    static Map<String, Object> advertisement(ScanResult r) {
        Map<String, Object> adv = BleCore.obj();
        ScanRecord rec = r.getScanRecord();
        String name = rec == null ? null : rec.getDeviceName();
        if (name != null) adv.put("name", name);
        adv.put("rssi", r.getRssi());
        if (Build.VERSION.SDK_INT >= 26) adv.put("connectable", r.isConnectable());
        List<Object> services = new ArrayList<>();
        List<Object> manufacturer = new ArrayList<>();
        List<Object> serviceData = new ArrayList<>();
        if (rec != null) {
            if (rec.getServiceUuids() != null) {
                for (ParcelUuid u : rec.getServiceUuids()) services.add(u.getUuid().toString().toLowerCase(Locale.ROOT));
            }
            SparseArray<byte[]> m = rec.getManufacturerSpecificData();
            if (m != null) {
                for (int i = 0; i < m.size(); i++) {
                    manufacturer.add(BleCore.obj("id", m.keyAt(i), "hex", BleCore.hex(copy(m.valueAt(i)))));
                }
            }
            Map<ParcelUuid, byte[]> sd = rec.getServiceData();
            if (sd != null) {
                for (Map.Entry<ParcelUuid, byte[]> e : sd.entrySet()) {
                    serviceData.add(BleCore.obj("uuid", e.getKey().getUuid().toString().toLowerCase(Locale.ROOT),
                            "hex", BleCore.hex(copy(e.getValue()))));
                }
            }
            if (rec.getTxPowerLevel() != Integer.MIN_VALUE) adv.put("txPower", rec.getTxPowerLevel());
        }
        adv.put("services", services);
        adv.put("manufacturer", manufacturer);
        adv.put("serviceData", serviceData);
        return adv;
    }

    // ---- GATT client ----------------------------------------------------------------------------

    String connect(String id, int gen, boolean auto, boolean background) {
        BluetoothAdapter a = adapter();
        if (a == null || !a.isEnabled()) return "unavailable Bluetooth is " + adapterState();
        if (!BluetoothAdapter.checkBluetoothAddress(id)) return "unknown_device " + id;
        Session s = new Session(id, gen);
        try {
            BluetoothDevice d = a.getRemoteDevice(id);
            // A new callback object per attempt (finding 3): a late callback of an older attempt
            // carries the older gen and is dropped by the core. autoConnect only for the automatic
            // reconnect, which then waits for the device without a time limit.
            s.gatt = d.connectGatt(app, background, s, BluetoothDevice.TRANSPORT_LE);
        } catch (RuntimeException e) {
            return "connect_failed " + e.getClass().getSimpleName();
        }
        if (s.gatt == null) return "connect_failed the stack refused the connection";
        sessions.put(gen, s);
        return null;
    }

    private void connectionState(Session s, int status, int newState) {
        if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
            s.connected = true;
            core.connected(s.id, s.gen, 23);
            return;
        }
        if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
            // The platform's own duty: a disconnected BluetoothGatt is closed by its owner.
            closeGatt(s);
            core.disconnected(s.id, s.gen, status == BluetoothGatt.GATT_SUCCESS ? "remote" : "status " + status,
                    status == BluetoothGatt.GATT_SUCCESS ? null : gattError(status));
        }
    }

    /** The GATT status of a failed or dropped link as the page sees it (the same shape as iOS's
     *  NSError domain, code and description). */
    static java.util.Map<String, Object> gattError(int status) {
        return BleCore.platformError("android.bluetooth.BluetoothGatt", status, "GATT status " + status);
    }

    private void closeGatt(Session s) {
        if (sessions.remove(s.gen) == null) return;
        try {
            s.gatt.close();
        } catch (RuntimeException ignored) {
            // Already closed by the stack.
        }
    }

    boolean close(String id, int gen) {
        Session s = sessions.get(gen);
        if (s == null) return true;
        if (!s.connected) {
            // A pending connect gives no callback when cancelled: close at once, confirmed.
            try {
                s.gatt.disconnect();
            } catch (RuntimeException ignored) {
                // Nothing to cancel.
            }
            closeGatt(s);
            return true;
        }
        s.closing = true;
        try {
            s.gatt.disconnect();
        } catch (RuntimeException e) {
            closeGatt(s);
            return true;
        }
        return false;
    }

    void release(String id, int gen) {
        Session s = sessions.get(gen);
        if (s != null) closeGatt(s);
    }

    private void discovered(Session s, int status) {
        if (!"discover".equals(s.pendingKind)) return;
        if (status != BluetoothGatt.GATT_SUCCESS) {
            fail(s, "gatt_error", "service discovery failed (status " + status + ")");
            return;
        }
        List<Object> out = new ArrayList<>();
        Map<String, Integer> sn = new HashMap<>();
        for (BluetoothGattService svc : s.gatt.getServices()) {
            String su = svc.getUuid().toString().toLowerCase(Locale.ROOT);
            int n = sn.merge(su, 1, Integer::sum) - 1;
            List<Object> chars = new ArrayList<>();
            Map<String, Integer> cn = new HashMap<>();
            for (BluetoothGattCharacteristic c : svc.getCharacteristics()) {
                String cu = c.getUuid().toString().toLowerCase(Locale.ROOT);
                int m = cn.merge(cu, 1, Integer::sum) - 1;
                List<Object> descs = new ArrayList<>();
                for (BluetoothGattDescriptor d : c.getDescriptors()) descs.add(d.getUuid().toString().toLowerCase(Locale.ROOT));
                chars.add(BleCore.obj("uuid", cu, "n", m, "properties", properties(c.getProperties()), "descriptors", descs));
            }
            List<Object> included = new ArrayList<>();
            for (BluetoothGattService inc : svc.getIncludedServices()) included.add(inc.getUuid().toString().toLowerCase(Locale.ROOT));
            out.add(BleCore.obj("uuid", su, "n", n, "primary", svc.getType() == BluetoothGattService.SERVICE_TYPE_PRIMARY,
                    "included", included, "characteristics", chars));
        }
        complete(s, null, null, BleCore.obj("services", out));
    }

    static List<Object> properties(int p) {
        List<Object> out = new ArrayList<>();
        if ((p & BluetoothGattCharacteristic.PROPERTY_BROADCAST) != 0) out.add("broadcast");
        if ((p & BluetoothGattCharacteristic.PROPERTY_READ) != 0) out.add("read");
        if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0) out.add("writeWithoutResponse");
        if ((p & BluetoothGattCharacteristic.PROPERTY_WRITE) != 0) out.add("write");
        if ((p & BluetoothGattCharacteristic.PROPERTY_NOTIFY) != 0) out.add("notify");
        if ((p & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) out.add("indicate");
        if ((p & BluetoothGattCharacteristic.PROPERTY_SIGNED_WRITE) != 0) out.add("authenticatedSignedWrites");
        if ((p & BluetoothGattCharacteristic.PROPERTY_EXTENDED_PROPS) != 0) out.add("extendedProperties");
        return out;
    }

    /** The key of a characteristic: service and characteristic UUIDs with their instance numbers. */
    static String keyOf(BluetoothGatt g, BluetoothGattCharacteristic c) {
        BluetoothGattService svc = c.getService();
        int sn = 0;
        for (BluetoothGattService x : g.getServices()) {
            if (x == svc) break;
            if (x.getUuid().equals(svc.getUuid())) sn++;
        }
        int cn = 0;
        for (BluetoothGattCharacteristic x : svc.getCharacteristics()) {
            if (x == c) break;
            if (x.getUuid().equals(c.getUuid())) cn++;
        }
        return BleCore.key(svc.getUuid().toString().toLowerCase(Locale.ROOT), sn, c.getUuid().toString().toLowerCase(Locale.ROOT), cn);
    }

    private static BluetoothGattCharacteristic resolve(BluetoothGatt g, String key) {
        String[] p = key.split("[#/]");
        UUID su = UUID.fromString(p[0]), cu = UUID.fromString(p[2]);
        int sn = Integer.parseInt(p[1]), cn = Integer.parseInt(p[3]);
        for (BluetoothGattService svc : g.getServices()) {
            if (!svc.getUuid().equals(su) || sn-- > 0) continue;
            for (BluetoothGattCharacteristic c : svc.getCharacteristics()) {
                if (c.getUuid().equals(cu) && cn-- == 0) return c;
            }
            return null;
        }
        return null;
    }

    @SuppressWarnings("deprecation")
    String op(String id, int gen, int op, String kind, String key, String descriptor, byte[] data, int arg) {
        Session s = sessions.get(gen);
        if (s == null || !s.connected) return "not_connected the link is not connected";
        BluetoothGatt g = s.gatt;
        try {
            if ("mtu".equals(kind)) {
                return begin(s, op, kind, null, g.requestMtu(arg), "requestMtu");
            }
            if ("discover".equals(kind)) {
                return begin(s, op, kind, null, g.discoverServices(), "discoverServices");
            }
            if ("rssi".equals(kind)) {
                return begin(s, op, kind, null, g.readRemoteRssi(), "readRemoteRssi");
            }
            BluetoothGattCharacteristic c = resolve(g, key);
            if (c == null) return "not_found no such characteristic (run discover first)";
            int props = c.getProperties();
            BluetoothGattDescriptor d = null;
            if (descriptor != null) {
                d = c.getDescriptor(UUID.fromString(descriptor));
                if (d == null) return "not_found no such descriptor";
            }
            switch (kind) {
                case "read":
                    if (d != null) return begin(s, op, kind, null, g.readDescriptor(d), "readDescriptor");
                    if ((props & BluetoothGattCharacteristic.PROPERTY_READ) == 0) return "not_permitted the characteristic is not readable";
                    return begin(s, op, kind, null, g.readCharacteristic(c), "readCharacteristic");
                case "write":
                    if (d != null) {
                        if (CCCD.equals(d.getUuid())) return "not_permitted the CCCD is written by subscribe";
                        return begin(s, op, kind, null, writeDescriptor(g, d, data), "writeDescriptor");
                    }
                    if ((props & BluetoothGattCharacteristic.PROPERTY_WRITE) == 0) {
                        return "not_permitted the characteristic does not accept a write with response";
                    }
                    return begin(s, op, kind, null, writeCharacteristic(g, c, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT),
                            "writeCharacteristic");
                case "wnr":
                    if ((props & BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0) {
                        return "not_permitted the characteristic does not accept a write without response";
                    }
                    return begin(s, op, kind, null, writeCharacteristic(g, c, data, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE),
                            "writeCharacteristic");
                case "sub":
                case "unsub": {
                    boolean on = "sub".equals(kind);
                    boolean indicate = (props & BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
                            && (props & BluetoothGattCharacteristic.PROPERTY_NOTIFY) == 0;
                    if ((props & (BluetoothGattCharacteristic.PROPERTY_NOTIFY | BluetoothGattCharacteristic.PROPERTY_INDICATE)) == 0) {
                        return "not_permitted the characteristic neither notifies nor indicates";
                    }
                    BluetoothGattDescriptor cccd = c.getDescriptor(CCCD);
                    if (cccd == null) return "not_found the characteristic has no CCCD";
                    if (!g.setCharacteristicNotification(c, on)) return "gatt_error setCharacteristicNotification was refused";
                    byte[] v = !on ? BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                            : indicate ? BluetoothGattDescriptor.ENABLE_INDICATION_VALUE : BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE;
                    return begin(s, op, kind, on ? (indicate ? "indicate" : "notify") : null, writeDescriptor(g, cccd, v), "writeDescriptor");
                }
                default:
                    return "bad_value unknown operation " + kind;
            }
        } catch (SecurityException e) {
            return "permission_denied Bluetooth access was revoked";
        } catch (RuntimeException e) {
            return "gatt_error " + e.getClass().getSimpleName();
        }
    }

    @SuppressWarnings("deprecation")
    private static boolean writeCharacteristic(BluetoothGatt g, BluetoothGattCharacteristic c, byte[] data, int type) {
        if (Build.VERSION.SDK_INT >= 33) {
            // The API 33 form returns a BluetoothStatusCodes value; SUCCESS is 0.
            return g.writeCharacteristic(c, data, type) == 0;
        }
        c.setWriteType(type);
        c.setValue(data);
        return g.writeCharacteristic(c);
    }

    @SuppressWarnings("deprecation")
    private static boolean writeDescriptor(BluetoothGatt g, BluetoothGattDescriptor d, byte[] data) {
        if (Build.VERSION.SDK_INT >= 33) return g.writeDescriptor(d, data) == 0;
        d.setValue(data);
        return g.writeDescriptor(d);
    }

    private static String begin(Session s, int op, String kind, String mode, boolean accepted, String call) {
        if (!accepted) return "gatt_error " + call + " was refused by the stack";
        s.pendingOp = op;
        s.pendingKind = kind;
        s.pendingMode = mode;
        return null;
    }

    private void done(Session s, int status, Map<String, Object> data) {
        if (status != BluetoothGatt.GATT_SUCCESS) {
            fail(s, status == BluetoothGatt.GATT_READ_NOT_PERMITTED || status == BluetoothGatt.GATT_WRITE_NOT_PERMITTED
                    ? "not_permitted" : "gatt_error", "status " + status);
            return;
        }
        complete(s, null, null, data);
    }

    private void fail(Session s, String code, String message) {
        complete(s, code, message, null);
    }

    private void complete(Session s, String code, String message, Map<String, Object> data) {
        int op = s.pendingOp;
        s.pendingKind = null;
        s.pendingMode = null;
        core.opDone(s.id, s.gen, op, code, message, data);
    }

    // ---- GATT server ----------------------------------------------------------------------------

    /** ATT error codes the platform has no constant for (Bluetooth Core, Vol 3, Part F, 3.4.1.1). */
    static final int ATT_ATTRIBUTE_NOT_FOUND = 0x0A;
    static final int ATT_UNLIKELY = 0x0E;

    /**
     * The GATT server of one epoch: its own platform object and its own callback, like a client
     * Session. Bluetooth going off ends it; the core re-adds its services under the next epoch.
     */
    final class Server extends BluetoothGattServerCallback {
        final int epoch;
        BluetoothGattServer gatt;
        final Map<String, BluetoothGattService> table = new HashMap<>();
        /** The notification packet onNotificationSent answers (the core sends one at a time). */
        int packet;

        Server(int epoch) {
            this.epoch = epoch;
        }

        @Override
        public void onConnectionStateChange(BluetoothDevice device, int status, int newState) {
            String id = device.getAddress();
            boolean up = newState == BluetoothProfile.STATE_CONNECTED;
            main.post(() -> serverConnection(this, id, up));
        }

        @Override
        public void onServiceAdded(int status, BluetoothGattService service) {
            String u = service.getUuid().toString().toLowerCase(Locale.ROOT);
            main.post(() -> core.serviceAdded(epoch, u, status == BluetoothGatt.GATT_SUCCESS ? null : "status " + status));
        }

        @Override
        public void onMtuChanged(BluetoothDevice device, int mtu) {
            String id = device.getAddress();
            main.post(() -> core.centralMtu(epoch, id, mtu));
        }

        @Override
        public void onCharacteristicReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattCharacteristic c) {
            String id = device.getAddress();
            String k = serverKey(c);
            main.post(() -> readRequest(this, device, id, requestId, offset, k));
        }

        @Override
        public void onCharacteristicWriteRequest(BluetoothDevice device, int requestId, BluetoothGattCharacteristic c,
                                                 boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            String id = device.getAddress();
            String k = serverKey(c);
            byte[] v = copy(value);
            main.post(() -> writeRequest(this, device, id, requestId, k, preparedWrite, responseNeeded, offset, v));
        }

        @Override
        public void onDescriptorReadRequest(BluetoothDevice device, int requestId, int offset, BluetoothGattDescriptor d) {
            String id = device.getAddress();
            boolean cccd = CCCD.equals(d.getUuid());
            String k = serverKey(d.getCharacteristic());
            main.post(() -> cccdRead(this, device, id, requestId, offset, cccd, k));
        }

        @Override
        public void onDescriptorWriteRequest(BluetoothDevice device, int requestId, BluetoothGattDescriptor d,
                                             boolean preparedWrite, boolean responseNeeded, int offset, byte[] value) {
            String id = device.getAddress();
            boolean cccd = CCCD.equals(d.getUuid());
            String k = serverKey(d.getCharacteristic());
            byte[] v = copy(value);
            main.post(() -> cccdWrite(this, device, id, requestId, cccd, k, preparedWrite, responseNeeded, offset, v));
        }

        @Override
        public void onExecuteWrite(BluetoothDevice device, int requestId, boolean execute) {
            String id = device.getAddress();
            main.post(() -> respond(this, device, requestId, status(core.executeWrite(epoch, id, execute), false), 0, null));
        }

        @Override
        public void onNotificationSent(BluetoothDevice device, int status) {
            main.post(() -> core.notifySent(epoch, packet, status == BluetoothGatt.GATT_SUCCESS ? null : "status " + status));
        }
    }

    private Server server;

    private BluetoothManager manager() {
        return (BluetoothManager) app.getSystemService(Context.BLUETOOTH_SERVICE);
    }

    /** The server of {@code epoch}, opened on first use; an older epoch's server is closed first. */
    private Server serverFor(int epoch) {
        if (server != null && server.epoch == epoch) return server;
        closeServer();
        BluetoothManager m = manager();
        if (m == null) return null;
        Server s = new Server(epoch);
        try {
            s.gatt = m.openGattServer(app, s);
        } catch (RuntimeException e) {
            return null;
        }
        if (s.gatt == null) return null;
        server = s;
        return s;
    }

    private void closeServer() {
        Server s = server;
        server = null;
        if (s == null) return;
        try {
            s.gatt.close();
        } catch (RuntimeException ignored) {
            // The stack already ended it (Bluetooth off).
        }
    }

    /** The core's key of a local characteristic: one instance per service UUID, so the service number is 0. */
    static String serverKey(BluetoothGattCharacteristic c) {
        if (c == null) return null;
        BluetoothGattService svc = c.getService();
        int cn = 0;
        for (BluetoothGattCharacteristic x : svc.getCharacteristics()) {
            if (x == c) break;
            if (x.getUuid().equals(c.getUuid())) cn++;
        }
        return BleCore.key(svc.getUuid().toString().toLowerCase(Locale.ROOT), 0, c.getUuid().toString().toLowerCase(Locale.ROOT), cn);
    }

    private static BluetoothGattCharacteristic resolveLocal(Server s, String key) {
        String[] p = key.split("[#/]");
        BluetoothGattService svc = s.table.get(p[0]);
        if (svc == null) return null;
        UUID cu = UUID.fromString(p[2]);
        int cn = Integer.parseInt(p[3]);
        for (BluetoothGattCharacteristic c : svc.getCharacteristics()) {
            if (c.getUuid().equals(cu) && cn-- == 0) return c;
        }
        return null;
    }

    /** A central's link to this server; links this app opened as a client are the client's, not a central. */
    private void serverConnection(Server s, String id, boolean up) {
        if (up) {
            for (Session x : sessions.values()) if (x.id.equals(id)) return;
            core.centralConnected(s.epoch, id, 23);
        } else {
            core.centralDisconnected(s.epoch, id);
        }
    }

    /** The ATT status of a core outcome. */
    static int status(String outcome, boolean read) {
        switch (outcome) {
            case "ok":
                return BluetoothGatt.GATT_SUCCESS;
            case "not_found":
                return ATT_ATTRIBUTE_NOT_FOUND;
            case "not_permitted":
                return read ? BluetoothGatt.GATT_READ_NOT_PERMITTED : BluetoothGatt.GATT_WRITE_NOT_PERMITTED;
            case "invalid_offset":
                return BluetoothGatt.GATT_INVALID_OFFSET;
            case "invalid_length":
                return BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH;
            default:
                return ATT_UNLIKELY;
        }
    }

    private void respond(Server s, BluetoothDevice device, int requestId, int status, int offset, byte[] value) {
        try {
            s.gatt.sendResponse(device, requestId, status, offset, value);
        } catch (RuntimeException ignored) {
            // The server of that epoch is closed; the central's request ends with the link.
        }
    }

    private void readRequest(Server s, BluetoothDevice device, String id, int requestId, int offset, String key) {
        Map<String, Object> r = key == null ? BleCore.obj("status", "not_found") : core.readRequest(s.epoch, id, 0, key, offset);
        String hex = (String) r.get("hex");
        respond(s, device, requestId, status((String) r.get("status"), true), offset, hex == null ? null : BleCore.fromHex(hex));
    }

    private void writeRequest(Server s, BluetoothDevice device, String id, int requestId, String key, boolean prepared,
                              boolean responseNeeded, int offset, byte[] value) {
        String r = key == null ? "not_found" : core.writeRequests(s.epoch, id, 0,
                Collections.singletonList(BleCore.obj("key", key, "offset", offset, "hex", BleCore.hex(value))), prepared);
        if (responseNeeded) respond(s, device, requestId, status(r, false), offset, prepared ? value : null);
    }

    /** The CCCD is served here (Android leaves it to the app); any other descriptor is not in the table. */
    private void cccdRead(Server s, BluetoothDevice device, String id, int requestId, int offset, boolean cccd, String key) {
        if (!cccd || key == null) {
            respond(s, device, requestId, ATT_ATTRIBUTE_NOT_FOUND, offset, null);
            return;
        }
        byte[] v = BleCore.fromHex(core.cccd(id, key));
        if (offset > v.length) {
            respond(s, device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null);
            return;
        }
        respond(s, device, requestId, BluetoothGatt.GATT_SUCCESS, offset, java.util.Arrays.copyOfRange(v, offset, v.length));
    }

    private void cccdWrite(Server s, BluetoothDevice device, String id, int requestId, boolean cccd, String key,
                           boolean prepared, boolean responseNeeded, int offset, byte[] value) {
        int st;
        if (!cccd || key == null) {
            st = ATT_ATTRIBUTE_NOT_FOUND;
        } else if (prepared || offset != 0 || value.length != 2) {
            st = BluetoothGatt.GATT_INVALID_ATTRIBUTE_LENGTH;
        } else {
            String mode = (value[0] & 2) != 0 ? "indicate" : (value[0] & 1) != 0 ? "notify" : null;
            st = status(core.subscription(s.epoch, id, 0, key, mode), false);
        }
        if (responseNeeded) respond(s, device, requestId, st, offset, null);
    }

    String serviceAdd(int epoch, String uuid, boolean primary, List<Map<String, Object>> chars) {
        BluetoothAdapter a = adapter();
        if (a == null || !a.isEnabled()) return "unavailable Bluetooth is " + adapterState();
        Server s = serverFor(epoch);
        if (s == null) return "unavailable the GATT server could not be opened";
        BluetoothGattService svc = new BluetoothGattService(UUID.fromString(uuid),
                primary ? BluetoothGattService.SERVICE_TYPE_PRIMARY : BluetoothGattService.SERVICE_TYPE_SECONDARY);
        for (Map<String, Object> c : chars) {
            String f = (String) c.get("flags");
            int props = 0, perms = 0;
            if (f.indexOf('r') >= 0) {
                props |= BluetoothGattCharacteristic.PROPERTY_READ;
                perms |= f.indexOf('R') >= 0 ? BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED
                        : BluetoothGattCharacteristic.PERMISSION_READ;
            }
            if (f.indexOf('w') >= 0) props |= BluetoothGattCharacteristic.PROPERTY_WRITE;
            if (f.indexOf('c') >= 0) props |= BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE;
            if (f.indexOf('w') >= 0 || f.indexOf('c') >= 0) {
                perms |= f.indexOf('W') >= 0 ? BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED
                        : BluetoothGattCharacteristic.PERMISSION_WRITE;
            }
            if (f.indexOf('n') >= 0) props |= BluetoothGattCharacteristic.PROPERTY_NOTIFY;
            if (f.indexOf('i') >= 0) props |= BluetoothGattCharacteristic.PROPERTY_INDICATE;
            BluetoothGattCharacteristic ch = new BluetoothGattCharacteristic(UUID.fromString((String) c.get("uuid")), props, perms);
            if (f.indexOf('n') >= 0 || f.indexOf('i') >= 0) {
                ch.addDescriptor(new BluetoothGattDescriptor(CCCD,
                        BluetoothGattDescriptor.PERMISSION_READ | BluetoothGattDescriptor.PERMISSION_WRITE));
            }
            svc.addCharacteristic(ch);
        }
        try {
            if (!s.gatt.addService(svc)) return "gatt_error addService was refused by the stack";
        } catch (SecurityException e) {
            return "permission_denied Bluetooth access was revoked";
        } catch (RuntimeException e) {
            return "gatt_error " + e.getClass().getSimpleName();
        }
        s.table.put(uuid, svc);
        return null;
    }

    void serviceRemove(String uuid) {
        Server s = server;
        BluetoothGattService svc = s == null ? null : s.table.remove(uuid);
        if (svc == null) return;
        try {
            s.gatt.removeService(svc);
        } catch (RuntimeException ignored) {
            // Bluetooth went off meanwhile: the service is gone with the server.
        }
    }

    @SuppressWarnings("deprecation")
    String notify(int epoch, int packet, String central, String key, byte[] data, boolean indicate) {
        Server s = server;
        if (s == null || s.epoch != epoch) return "unavailable the GATT server is closed";
        BluetoothGattCharacteristic c = resolveLocal(s, key);
        BluetoothAdapter a = adapter();
        if (c == null || a == null) return "not_found the characteristic is not in the server";
        try {
            BluetoothDevice d = a.getRemoteDevice(central);
            if (Build.VERSION.SDK_INT >= 33) {
                // The API 33 form returns a BluetoothStatusCodes value; SUCCESS is 0.
                int r = s.gatt.notifyCharacteristicChanged(d, c, indicate, data);
                if (r != 0) return "gatt_error notifyCharacteristicChanged returned " + r;
            } else {
                c.setValue(data);
                if (!s.gatt.notifyCharacteristicChanged(d, c, indicate)) return "gatt_error notifyCharacteristicChanged was refused";
            }
        } catch (SecurityException e) {
            return "permission_denied Bluetooth access was revoked";
        } catch (RuntimeException e) {
            return "gatt_error " + e.getClass().getSimpleName();
        }
        s.packet = packet;
        return "pending";
    }

    void centralDrop(String central) {
        Server s = server;
        BluetoothAdapter a = adapter();
        if (s == null || a == null) return;
        try {
            s.gatt.cancelConnection(a.getRemoteDevice(central));
        } catch (RuntimeException ignored) {
            // Already gone: centralDisconnected follows from the stack, or the link ended with Bluetooth.
        }
    }

    // ---- advertiser -----------------------------------------------------------------------------

    private final Map<Integer, AdvertiseCallback> advertisers = new HashMap<>();

    String advertiseStart(int epoch, int adv, Map<String, Object> p) {
        BluetoothAdapter a = adapter();
        if (a == null || !a.isEnabled()) return "unavailable Bluetooth is " + adapterState();
        BluetoothLeAdvertiser le = a.getBluetoothLeAdvertiser();
        if (le == null) return "platform_limit this device's Bluetooth controller cannot advertise";
        String mode = (String) p.get("mode");
        int m = "low_power".equals(mode) ? AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                : "low_latency".equals(mode) ? AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY : AdvertiseSettings.ADVERTISE_MODE_BALANCED;
        // The duration is the core's own timer; the platform's 180 s cap would end longer ones early.
        AdvertiseSettings settings = new AdvertiseSettings.Builder().setAdvertiseMode(m)
                .setConnectable(Boolean.TRUE.equals(p.get("connectable"))).setTimeout(0).build();
        AdvertiseData.Builder data = new AdvertiseData.Builder()
                .setIncludeDeviceName(p.get("name") != null).setIncludeTxPowerLevel(false);
        for (Object u : (List<?>) p.get("services")) data.addServiceUuid(ParcelUuid.fromString((String) u));
        if (p.get("manufacturerId") != null) {
            data.addManufacturerData((Integer) p.get("manufacturerId"), BleCore.fromHex((String) p.get("manufacturerHex")));
        }
        if (p.get("serviceDataUuid") != null) {
            data.addServiceData(ParcelUuid.fromString((String) p.get("serviceDataUuid")), BleCore.fromHex((String) p.get("serviceDataHex")));
        }
        AdvertiseCallback cb = new AdvertiseCallback() {
            @Override
            public void onStartSuccess(AdvertiseSettings settingsInEffect) {
                main.post(() -> core.advertiseStarted(epoch, adv, null));
            }

            @Override
            public void onStartFailure(int errorCode) {
                main.post(() -> core.advertiseStarted(epoch, adv, "error " + errorCode));
            }
        };
        try {
            le.startAdvertising(settings, data.build(), cb);
        } catch (SecurityException e) {
            return "permission_denied Bluetooth access was revoked";
        } catch (RuntimeException e) {
            return "advertise_failed " + e.getClass().getSimpleName();
        }
        advertisers.put(adv, cb);
        return null;
    }

    void advertiseStop(int adv) {
        AdvertiseCallback cb = advertisers.remove(adv);
        BluetoothAdapter a = adapter();
        BluetoothLeAdvertiser le = a == null ? null : a.getBluetoothLeAdvertiser();
        if (cb == null || le == null) return;
        try {
            le.stopAdvertising(cb);
        } catch (RuntimeException ignored) {
            // Bluetooth went off meanwhile: advertising ended with it.
        }
    }

    // ---- keep-alive -----------------------------------------------------------------------------

    /**
     * Starts (hold generation {@code hold}) or ends {@link BleLinkService}. A start needs a started
     * activity: from API 31 a foreground service cannot start from the background.
     */
    String keepAlive(boolean start, int hold, boolean foreground) {
        if (!start) {
            BleLinkService.release();
            return null;
        }
        if (!foreground) return "not_foreground no activity is started";
        if (!connectedDeviceAllowed()) return "not_permitted no permission for a connectedDevice foreground service";
        Intent i = new Intent(app, BleLinkService.class).putExtra(BleLinkService.EXTRA_HOLD, hold);
        try {
            if (Build.VERSION.SDK_INT >= 26) app.startForegroundService(i);
            else app.startService(i);
        } catch (SecurityException e) {
            return "not_permitted " + e.getClass().getSimpleName();
        } catch (IllegalStateException e) {
            // ForegroundServiceStartNotAllowedException (API 31) is an IllegalStateException.
            return "not_foreground " + e.getClass().getSimpleName();
        }
        return null;
    }

    /**
     * Android 14 (API 34) refuses {@code startForeground} with type {@code connectedDevice} unless the
     * app holds one of the permissions that type lists, and a service started with
     * {@code startForegroundService} that stops before entering the foreground crashes the app. So
     * the service is only started when the type's prerequisite holds. The list is the platform's,
     * from the foreground service types page (developer.android.com, read 2026-11-20).
     */
    boolean connectedDeviceAllowed() {
        if (Build.VERSION.SDK_INT < 34) return true;
        for (String p : CONNECTED_DEVICE_PERMISSIONS) {
            if (app.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED) return true;
        }
        return false;
    }

    static final String[] CONNECTED_DEVICE_PERMISSIONS = {
        "android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH_ADVERTISE",
        "android.permission.BLUETOOTH_SCAN", "android.permission.CHANGE_NETWORK_STATE",
        "android.permission.CHANGE_WIFI_STATE", "android.permission.CHANGE_WIFI_MULTICAST_STATE",
        "android.permission.NFC", "android.permission.TRANSMIT_IR", "android.permission.UWB_RANGING",
    };
}
