package despia.ext.ble;

import android.annotation.SuppressLint;
import android.annotation.TargetApi;
import android.app.Activity;
import android.app.PendingIntent;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.companion.AssociationInfo;
import android.companion.AssociationRequest;
import android.companion.BluetoothLeDeviceFilter;
import android.companion.CompanionDeviceManager;
import android.companion.DeviceNotAssociatedException;
import android.companion.ObservingDevicePresenceRequest;
import android.content.Context;
import android.content.Intent;
import android.content.IntentSender;
import android.content.pm.PackageManager;
import android.net.MacAddress;
import android.os.Build;
import android.os.Handler;
import android.os.ParcelUuid;
import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResult;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.IntentSenderRequest;
import androidx.activity.result.contract.ActivityResultContracts;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * Android restoration, the 1:1 of iOS state restoration (read 2026-11-25):
 *
 * <ul>
 *   <li>Wake scan: {@code BluetoothLeScanner.startScan(List, ScanSettings, PendingIntent)} (API 26). "Use
 *       this method of scanning if your process is not always running and it should be started when scan
 *       results are available." Results reach {@link BleWakeReceiver} with EXTRA_LIST_SCAN_RESULT or
 *       EXTRA_ERROR_CODE, and the system starts the process for it.
 *       https://developer.android.com/reference/android/bluetooth/le/BluetoothLeScanner#startScan(java.util.List%3Candroid.bluetooth.le.ScanFilter%3E,%20android.bluetooth.le.ScanSettings,%20android.app.PendingIntent)</li>
 *   <li>Device presence: CompanionDeviceManager associate (API 26; the AssociationInfo callback from API
 *       33) and startObservingDevicePresence (API 31; the ObservingDevicePresenceRequest form from API 36):
 *       "The app doesn't need to remain running in order to receive its callbacks", which reach
 *       {@link BlePresenceService}.
 *       https://developer.android.com/reference/android/companion/CompanionDeviceManager</li>
 * </ul>
 *
 * The wake filters, the observed associations and (API 26 to 32, where an association has no id) the
 * address-to-id table are kept in {@code ble/restore.json}, so a process the system started knows them.
 */
final class BleRestore {
    static final String WAKE_ACTION = "despia.ext.ble.WAKE";
    private static final int WAKE_REQUEST = 0x424c45;

    private final Context app;
    private final File file;
    private JSONObject saved = new JSONObject();

    BleRestore(Context app, File dir, Chooser chooser) {
        this.app = app;
        this.chooser = chooser;
        this.file = new File(dir, "restore.json");
        try {
            if (file.exists()) saved = new JSONObject(ServerMirror.readText(file));
        } catch (Exception e) {
            saved = new JSONObject();
        }
    }

    // ---- the kept state ------------------------------------------------------------------------------

    Map<String, Object> savedWake() {
        JSONObject w = saved.optJSONObject("wake");
        try {
            return w == null ? null : BleExtension.fromJson(w);
        } catch (JSONException e) {
            return null;
        }
    }

    List<Integer> savedObserving() {
        List<Integer> out = new ArrayList<>();
        JSONArray a = saved.optJSONArray("observing");
        if (a != null) for (int i = 0; i < a.length(); i++) out.add(a.optInt(i));
        return out;
    }

    void saveWake(Map<String, Object> filters) {
        try {
            if (filters == null) saved.remove("wake");
            else saved.put("wake", BleExtension.toJson(filters));
        } catch (JSONException ignored) {
            // The core built the filters from JSON-safe values.
        }
        write();
    }

    void saveObserving(List<Integer> list) {
        try {
            saved.put("observing", new JSONArray(list));
        } catch (JSONException ignored) {
            // Not reachable for a string key and integers.
        }
        write();
    }

    private void write() {
        try (FileOutputStream out = new FileOutputStream(file, false)) {
            out.write(saved.toString().getBytes(StandardCharsets.UTF_8));
        } catch (Exception ignored) {
            // A lost write keeps the previous state; the system's scan and observation are unchanged.
        }
    }

    /** API 26 to 32: the id this extension gave an associated address (CompanionDeviceManager gives none). */
    private int idOf(String address) {
        JSONObject ids = saved.optJSONObject("ids");
        if (ids == null) {
            ids = new JSONObject();
            try {
                saved.put("ids", ids);
            } catch (JSONException ignored) {
                // Not reachable for a fresh object.
            }
        }
        int id = ids.optInt(address, 0);
        if (id == 0) {
            id = saved.optInt("nextId", 0) + 1;
            try {
                ids.put(address, id);
                saved.put("nextId", id);
            } catch (JSONException ignored) {
                // Not reachable for a string key.
            }
            write();
        }
        return id;
    }

    String addressOf(int id) {
        if (Build.VERSION.SDK_INT >= 33) {
            CompanionDeviceManager m = cdm();
            if (m == null) return null;
            for (AssociationInfo a : m.getMyAssociations()) {
                if (a.getId() == id) return a.getDeviceMacAddress() == null ? null : mac(a.getDeviceMacAddress());
            }
            return null;
        }
        JSONObject ids = saved.optJSONObject("ids");
        if (ids == null) return null;
        for (Iterator<String> it = ids.keys(); it.hasNext(); ) {
            String k = it.next();
            if (ids.optInt(k) == id) return k;
        }
        return null;
    }

    int idForAddress(String address) {
        return address == null ? 0 : idOf(address.toUpperCase(Locale.ROOT));
    }

    private void forget(String address) {
        JSONObject ids = saved.optJSONObject("ids");
        if (ids != null) ids.remove(address);
        write();
    }

    static List<String> strings(Object o) {
        List<String> out = new ArrayList<>();
        if (o instanceof List) for (Object x : (List<?>) o) if (x instanceof String) out.add((String) x);
        return out;
    }

    static String mac(MacAddress m) {
        return m.toString().toUpperCase(Locale.ROOT);
    }

    // ---- wake scan -----------------------------------------------------------------------------------

    private PendingIntent wakeIntent() {
        Intent i = new Intent(app, BleWakeReceiver.class).setAction(WAKE_ACTION).setPackage(app.getPackageName());
        // The system adds the results as extras, so the intent is mutable (API 31 asks for the flag); never
        // FLAG_CANCEL_CURRENT, which stopScan(PendingIntent) asks not to use.
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
        return PendingIntent.getBroadcast(app, WAKE_REQUEST, i, flags);
    }

    private BluetoothLeScanner scanner() {
        BluetoothManager m = (BluetoothManager) app.getSystemService(Context.BLUETOOTH_SERVICE);
        BluetoothAdapter a = m == null ? null : m.getAdapter();
        return a == null || !a.isEnabled() ? null : a.getBluetoothLeScanner();
    }

    @SuppressLint("MissingPermission") // BleExtension.role asks the scan grant before the route runs.
    String wakeStart(Map<String, Object> f, String mode) {
        if (Build.VERSION.SDK_INT < 26) return "platform_limit a scan that wakes the app needs Android 8.0 (API 26)";
        BluetoothLeScanner s = scanner();
        if (s == null) return "unavailable Bluetooth is off";
        List<String> services = strings(f.get("services"));
        List<String> names = strings(f.get("names"));
        int id = f.get("manufacturer_id") instanceof Integer ? (Integer) f.get("manufacturer_id") : -1;
        byte[] prefix = id >= 0 ? BleCore.fromHex((String) f.get("manufacturer_hex")) : null;
        List<ScanFilter> filters = AndroidRadio.filters(services, names, id, prefix);
        int m = "low_latency".equals(mode) ? ScanSettings.SCAN_MODE_LOW_LATENCY
                : "balanced".equals(mode) ? ScanSettings.SCAN_MODE_BALANCED
                : "opportunistic".equals(mode) ? ScanSettings.SCAN_MODE_OPPORTUNISTIC : ScanSettings.SCAN_MODE_LOW_POWER;
        ScanSettings settings = new ScanSettings.Builder().setScanMode(m).build();
        int r;
        try {
            r = s.startScan(filters, settings, wakeIntent());
        } catch (RuntimeException e) {
            return "scan_failed the wake scan could not start (" + e.getClass().getSimpleName() + ")";
        }
        return r == 0 ? null : "scan_failed the wake scan could not start (error " + r + ")";
    }

    @SuppressLint("MissingPermission")
    void wakeStop() {
        if (Build.VERSION.SDK_INT < 26) return;
        BluetoothLeScanner s = scanner();
        if (s == null) return;
        try {
            s.stopScan(wakeIntent());
        } catch (RuntimeException ignored) {
            // Bluetooth turned off meanwhile: the system ended the scan.
        }
    }

    /** The receiver's intent: the device records, in the core's form, or the SCAN_FAILED code. */
    static int wakeError(Intent intent) {
        return intent.getIntExtra(BluetoothLeScanner.EXTRA_ERROR_CODE, 0);
    }

    @SuppressWarnings("deprecation")
    static List<Map<String, Object>> wakeDevices(Intent intent) {
        List<Map<String, Object>> out = new ArrayList<>();
        List<ScanResult> list = Build.VERSION.SDK_INT >= 33
                ? intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT, ScanResult.class)
                : intent.getParcelableArrayListExtra(BluetoothLeScanner.EXTRA_LIST_SCAN_RESULT);
        if (list == null) return out;
        for (ScanResult r : list) {
            Map<String, Object> d = BleCore.obj("id", r.getDevice().getAddress());
            d.putAll(AndroidRadio.advertisement(r));
            out.add(d);
        }
        return out;
    }

    // ---- companion device association and presence ---------------------------------------------------

    private CompanionDeviceManager cdm() {
        if (Build.VERSION.SDK_INT < 26) return null;
        if (!app.getPackageManager().hasSystemFeature(PackageManager.FEATURE_COMPANION_DEVICE_SETUP)) return null;
        return (CompanionDeviceManager) app.getSystemService(Context.COMPANION_DEVICE_SERVICE);
    }

    private static final String NO_CDM = "unavailable this device has no companion device setup (FEATURE_COMPANION_DEVICE_SETUP)";

    /** Where the end of a chooser request goes (BleCore.associated). */
    interface Chooser {
        void done(int request, Map<String, Object> info, String err);
    }

    private ActivityResultLauncher<IntentSenderRequest> chooserLauncher;
    private int chooserRequest;
    private final Chooser chooser;

    /** The activity was created: the chooser is launched from it, like the permission request. */
    void attach(ComponentActivity a, String key) {
        detach();
        chooserLauncher = a.getActivityResultRegistry().register(key, new ActivityResultContracts.StartIntentSenderForResult(),
                (ActivityResult res) -> chooserResult(chooserRequest, res.getResultCode() == Activity.RESULT_OK, res.getData()));
    }

    void detach() {
        if (chooserLauncher != null) chooserLauncher.unregister();
        chooserLauncher = null;
    }

    private boolean launch(int request, IntentSender sender) {
        if (chooserLauncher == null) return false;
        chooserRequest = request;
        chooserLauncher.launch(new IntentSenderRequest.Builder(sender).build());
        return true;
    }

    @SuppressWarnings("deprecation") // API 26 to 32: associate with a Handler and onDeviceFound.
    String associate(int request, Map<String, Object> p, Handler main) {
        if (Build.VERSION.SDK_INT < 26) return "platform_limit CompanionDeviceManager needs Android 8.0 (API 26)";
        CompanionDeviceManager m = cdm();
        if (m == null) return NO_CDM;
        ScanFilter.Builder sf = new ScanFilter.Builder();
        List<String> services = strings(p.get("services"));
        if (!services.isEmpty()) sf.setServiceUuid(ParcelUuid.fromString(services.get(0)));
        if (p.get("name") instanceof String) sf.setDeviceName((String) p.get("name"));
        if (p.get("address") instanceof String) sf.setDeviceAddress((String) p.get("address"));
        AssociationRequest req = new AssociationRequest.Builder()
                .addDeviceFilter(new BluetoothLeDeviceFilter.Builder().setScanFilter(sf.build()).build())
                .setSingleDevice(Boolean.TRUE.equals(p.get("single")))
                .build();
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                m.associate(req, main::post, new CompanionDeviceManager.Callback() {
                    @Override
                    public void onAssociationPending(IntentSender sender) {
                        if (!launch(request, sender)) chooser.done(request, null, "unavailable no activity can show the device chooser");
                    }

                    @Override
                    public void onAssociationCreated(AssociationInfo info) {
                        chooser.done(request, record(info), null);
                    }

                    @Override
                    public void onFailure(CharSequence error) {
                        chooser.done(request, null, "associate_failed " + error);
                    }
                });
            } else {
                m.associate(req, new CompanionDeviceManager.Callback() {
                    @Override
                    public void onDeviceFound(IntentSender sender) {
                        if (!launch(request, sender)) chooser.done(request, null, "unavailable no activity can show the device chooser");
                    }

                    @Override
                    public void onFailure(CharSequence error) {
                        chooser.done(request, null, "associate_failed " + error);
                    }
                }, main);
            }
        } catch (RuntimeException e) {
            return "associate_failed the device chooser could not open (" + e.getClass().getSimpleName() + ")";
        }
        return null;
    }

    /**
     * The chooser activity ended. API 33+: the association reaches onAssociationCreated, so only a cancel
     * ends the request here. API 26 to 32: RESULT_OK carries the chosen device in EXTRA_DEVICE.
     */
    @SuppressWarnings("deprecation")
    @SuppressLint("MissingPermission")
    private void chooserResult(int request, boolean ok, Intent data) {
        if (!ok) {
            chooser.done(request, null, "cancelled the device chooser was closed");
            return;
        }
        if (Build.VERSION.SDK_INT >= 33) return;
        Object d = data == null ? null : data.getParcelableExtra(CompanionDeviceManager.EXTRA_DEVICE);
        BluetoothDevice dev = d instanceof ScanResult ? ((ScanResult) d).getDevice() : d instanceof BluetoothDevice ? (BluetoothDevice) d : null;
        if (dev == null) {
            chooser.done(request, null, "associate_failed the chooser returned no device");
            return;
        }
        String address = dev.getAddress().toUpperCase(Locale.ROOT);
        String name = null;
        try {
            name = dev.getName();
        } catch (SecurityException ignored) {
            // API 31+: the name needs BLUETOOTH_CONNECT; the association stands without it.
        }
        chooser.done(request, BleCore.obj("association", idOf(address), "address", address, "name", name), null);
    }

    @TargetApi(33)
    private static Map<String, Object> record(AssociationInfo a) {
        CharSequence name = a.getDisplayName();
        return BleCore.obj("association", a.getId(), "address", a.getDeviceMacAddress() == null ? null : mac(a.getDeviceMacAddress()),
                "name", name == null ? null : name.toString());
    }

    @SuppressWarnings("deprecation")
    Object associations() {
        CompanionDeviceManager m = cdm();
        if (m == null) return Build.VERSION.SDK_INT < 26 ? "platform_limit CompanionDeviceManager needs Android 8.0 (API 26)" : NO_CDM;
        List<Object> out = new ArrayList<>();
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                for (AssociationInfo a : m.getMyAssociations()) out.add(record(a));
            } else {
                for (String address : m.getAssociations()) {
                    String a = address.toUpperCase(Locale.ROOT);
                    out.add(BleCore.obj("association", idOf(a), "address", a, "name", null));
                }
            }
        } catch (RuntimeException e) {
            return "associate_failed the associations could not be read (" + e.getClass().getSimpleName() + ")";
        }
        return out;
    }

    @SuppressWarnings("deprecation")
    String disassociate(int id) {
        CompanionDeviceManager m = cdm();
        if (m == null) return Build.VERSION.SDK_INT < 26 ? "platform_limit CompanionDeviceManager needs Android 8.0 (API 26)" : NO_CDM;
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                m.disassociate(id);
            } else {
                String a = addressOf(id);
                if (a == null) return "not_associated association " + id + " is not this app's";
                m.disassociate(a);
                forget(a);
            }
        } catch (RuntimeException e) {
            return "not_associated association " + id + " is not this app's (" + e.getClass().getSimpleName() + ")";
        }
        return null;
    }

    @SuppressWarnings("deprecation")
    @SuppressLint("MissingPermission") // REQUEST_OBSERVE_COMPANION_DEVICE_PRESENCE is in this module's manifest.
    String presence(boolean start, int id) {
        if (Build.VERSION.SDK_INT < 31) return "platform_limit observing a device's presence needs Android 12 (API 31)";
        CompanionDeviceManager m = cdm();
        if (m == null) return NO_CDM;
        try {
            if (Build.VERSION.SDK_INT >= 36) {
                ObservingDevicePresenceRequest r = new ObservingDevicePresenceRequest.Builder().setAssociationId(id).build();
                if (start) m.startObservingDevicePresence(r);
                else m.stopObservingDevicePresence(r);
            } else {
                String a = addressOf(id);
                if (a == null) return "not_associated association " + id + " is not this app's";
                if (start) m.startObservingDevicePresence(a);
                else m.stopObservingDevicePresence(a);
            }
        } catch (DeviceNotAssociatedException e) {
            return "not_associated association " + id + " is not this app's";
        } catch (SecurityException e) {
            return "permission_denied REQUEST_OBSERVE_COMPANION_DEVICE_PRESENCE is not granted";
        } catch (RuntimeException e) {
            return "presence_failed presence could not change (" + e.getClass().getSimpleName() + ")";
        }
        return null;
    }
}
