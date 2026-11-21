package despia.ext.ble;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.activity.ComponentActivity;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.core.content.ContextCompat;

import com.despia.nativeext.ExtCall;
import com.despia.nativeext.ExtContext;
import com.despia.nativeext.ExtResult;
import com.despia.nativeext.NativeExtension;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Universal Bluetooth LE for the page: scan, connect, GATT client, GATT server, advertising, the
 * keep-alive service and raw bytes. Every decision is
 * {@link BleCore}'s; {@link AndroidRadio} talks to the stack. This class owns the bridge side: route
 * parameters, permissions, one reply per call, events and timers, all on the main thread.
 *
 * <p>Permissions by role ({@link BleCore#permissions}): from API 31 the dashboard-owned
 * BLUETOOTH_SCAN (plus ACCESS_FINE_LOCATION unless the app declares BLUETOOTH_SCAN with
 * neverForLocation) and BLUETOOTH_CONNECT; on API 24 to 30 the install-time BLUETOOTH and
 * BLUETOOTH_ADMIN (declared by this module with maxSdkVersion 30) and ACCESS_FINE_LOCATION at
 * runtime. Advertising adds BLUETOOTH_ADVERTISE from API 31; the GATT server needs BLUETOOTH_CONNECT. A missing install-time grant is reported, never requested. Missing runtime permissions are
 * requested through the activity's ActivityResultRegistry under {@link ExtContext#resultKey},
 * registered on {@code created}; one request at a time.
 *
 * <p>Each route that needs a prompt is an attempt tied to its {@link ExtCall}: an answer after the
 * call timed out starts nothing, and a destroyed activity ends the wait, so nothing stays busy.
 * Nothing starts at launch: the adapter receiver is registered on the first route call.
 */
public final class BleExtension implements NativeExtension, BleCore.Port {
    private final Handler main = new Handler(Looper.getMainLooper());
    private ExtContext ctx;
    private BleCore core;
    private AndroidRadio radio;
    private boolean radioStarted;
    private ComponentActivity registeredOn;
    private ActivityResultLauncher<String[]> permission;
    private int startedActivities;
    /** The route waiting for a permission answer; one at a time. */
    private Attempt pending;
    private int nextCall;
    private final Map<Integer, Waiting> calls = new HashMap<>();

    private static final class Attempt {
        final ExtCall call;
        final ExtResult.Callback reply;
        final String role;
        boolean ended;

        Attempt(ExtCall call, ExtResult.Callback reply, String role) {
            this.call = call;
            this.reply = reply;
            this.role = role;
        }
    }

    private static final class Waiting {
        final ExtCall call;
        final ExtResult.Callback reply;

        Waiting(ExtCall call, ExtResult.Callback reply) {
            this.call = call;
            this.reply = reply;
        }
    }

    @Override
    public void onCreate(ExtContext context) {
        ctx = context;
        core = new BleCore(this, "android", UUID.randomUUID().toString());
        radio = new AndroidRadio(context.app(), main, core);
    }

    @Override
    public void onActivityEvent(Activity activity, ActivityEvent event) {
        if (event == ActivityEvent.STARTED) {
            if (startedActivities++ == 0 && radioStarted) core.background(false);
        } else if (event == ActivityEvent.STOPPED) {
            if (startedActivities > 0 && --startedActivities == 0 && radioStarted) core.background(true);
        }
        if (!(activity instanceof ComponentActivity)) return;
        ComponentActivity a = (ComponentActivity) activity;
        if (event == ActivityEvent.CREATED) {
            if (permission != null) permission.unregister();
            registeredOn = a;
            permission = a.getActivityResultRegistry().register(ctx.resultKey("permissions"),
                    new ActivityResultContracts.RequestMultiplePermissions(), (Map<String, Boolean> result) -> {
                        Attempt at = pending;
                        if (at == null || at.ended) return;
                        if (!at.call.isActive()) {
                            // A late Allow: the page already has the timeout. Start nothing.
                            finish(at, ExtResult.error("timeout", "Bluetooth was allowed after the route timed out"));
                        } else if (missingRuntime(at.role).isEmpty()) {
                            proceed(at);
                        } else {
                            finish(at, ExtResult.error("permission_denied", "Bluetooth access was denied"));
                        }
                    });
        } else if (event == ActivityEvent.DESTROYED && registeredOn == a && permission != null) {
            permission.unregister();
            permission = null;
            registeredOn = null;
            // Recreated (configuration, or the system reclaimed it): the permission answer reaches
            // the launcher the new activity registers under the same key, so the route waits.
            // Finishing: the answer can no longer arrive; the route waiting for it ends.
            if (pending != null && !pending.ended && a.isFinishing()) {
                finish(pending, ExtResult.error("unavailable", "the activity was destroyed"));
            }
        }
    }

    /** The permission role of a route; null when it touches no Bluetooth API that needs one. */
    static String role(String route, Map<String, Object> params) {
        switch (route) {
            case "scan_start":
                return "scan";
            case "advertise_start":
            case "advertise_stop":
                return "advertise";
            case "service_add":
            case "service_remove":
            case "notify":
            case "central_drop":
            case "connect":
            case "disconnect":
            case "discover":
            case "read":
            case "write":
            case "subscribe":
            case "unsubscribe":
            case "rssi":
            case "mtu":
                return "connect";
            case "state":
                return Boolean.TRUE.equals(params.get("prompt")) ? "central" : null;
            default:
                return null;
        }
    }

    @Override
    public void handle(ExtCall call, ExtResult.Callback reply) {
        String role = role(call.route, call.params);
        if (role == null) {
            dispatch(call, reply);
            return;
        }
        if (pending != null && !pending.ended && pending.call.isActive()) {
            reply.reply(ExtResult.error("busy", "a Bluetooth permission request is already open"));
            return;
        }
        Attempt at = new Attempt(call, reply, role);
        pending = at;
        String installTime = missingInstallTime(role);
        List<String> runtime = missingRuntime(role);
        if (installTime != null) {
            finish(at, ExtResult.error("unavailable", installTime + " is not declared in this build"));
        } else if (runtime.isEmpty()) {
            proceed(at);
        } else if (permission != null) {
            permission.launch(runtime.toArray(new String[0]));
        } else {
            finish(at, ExtResult.error("permission_denied", "Bluetooth access is not granted"));
        }
    }

    /** The permission is in place: hand the route to the core. Never leaves the slot taken. */
    private void proceed(Attempt at) {
        if (pending == at) pending = null;
        ExtResult.Callback once = r -> {
            if (at.ended) return;
            at.ended = true;
            at.reply.reply(r);
        };
        try {
            dispatch(at.call, once);
        } catch (RuntimeException e) {
            once.reply(ExtResult.error("handler_error", e.getClass().getSimpleName()));
        }
    }

    /** The one reply of {@code at}; frees the slot when it is still the pending attempt. */
    private void finish(Attempt at, ExtResult result) {
        if (pending == at) pending = null;
        if (at.ended) return;
        at.ended = true;
        at.reply.reply(result);
    }

    private void ensureRadio() {
        if (radioStarted) return;
        radioStarted = true;
        radio.start();
        core.adapter(radio.adapterState());
        core.background(startedActivities == 0);
    }

    private static int num(ExtCall call, String name, int dflt) {
        Object v = call.params.get(name);
        return v instanceof Number ? ((Number) v).intValue() : dflt;
    }

    private static boolean flag(ExtCall call, String name, boolean dflt) {
        Object v = call.params.get(name);
        return v instanceof Boolean ? (Boolean) v : dflt;
    }

    private static String str(ExtCall call, String name) {
        Object v = call.params.get(name);
        return v instanceof String ? (String) v : null;
    }

    private void dispatch(ExtCall call, ExtResult.Callback reply) {
        ensureRadio();
        int c = ++nextCall;
        calls.put(c, new Waiting(call, reply));
        String id = str(call, "id");
        switch (call.route) {
            case "state":
                state(c);
                return;
            case "events":
                core.events(c, num(call, "after", 0), num(call, "max", 200));
                return;
            case "scan_start":
                core.scanStart(c, str(call, "services"), num(call, "seconds", 0), flag(call, "duplicates", false),
                        call.params.containsKey("mode") ? str(call, "mode") : "balanced", startedActivities == 0);
                return;
            case "scan_stop":
                core.scanStop(c);
                return;
            case "devices":
                core.devices(c);
                return;
            case "connect":
                core.connect(c, id, flag(call, "auto", false), num(call, "seconds", 10));
                return;
            case "disconnect":
                core.disconnect(c, id);
                return;
            case "links":
                core.links(c);
                return;
            case "discover":
                core.discover(c, id);
                return;
            case "read":
                core.read(c, id, str(call, "service"), num(call, "service_n", 0), str(call, "char"), num(call, "char_n", 0),
                        str(call, "descriptor"));
                return;
            case "write":
                core.write(c, id, str(call, "service"), num(call, "service_n", 0), str(call, "char"), num(call, "char_n", 0),
                        str(call, "descriptor"), str(call, "hex"), str(call, "b64"), flag(call, "response", true));
                return;
            case "subscribe":
            case "unsubscribe":
                core.subscribe(c, id, str(call, "service"), num(call, "service_n", 0), str(call, "char"), num(call, "char_n", 0),
                        "subscribe".equals(call.route));
                return;
            case "rssi":
                core.rssi(c, id);
                return;
            case "mtu":
                core.mtu(c, id, num(call, "size", BleCore.MTU_REQUEST));
                return;
            case "service_add":
                core.serviceAdd(c, str(call, "uuid"), flag(call, "primary", true), str(call, "chars"));
                return;
            case "service_remove":
                core.serviceRemove(c, str(call, "uuid"));
                return;
            case "services":
                core.services(c);
                return;
            case "value_set":
                core.valueSet(c, str(call, "service"), str(call, "char"), num(call, "char_n", 0), str(call, "hex"), str(call, "b64"));
                return;
            case "notify":
                core.notify(c, str(call, "service"), str(call, "char"), num(call, "char_n", 0), str(call, "hex"), str(call, "b64"),
                        str(call, "central"));
                return;
            case "advertise_start":
                core.advertiseStart(c, str(call, "services"), str(call, "name"), num(call, "manufacturer_id", -1),
                        str(call, "manufacturer_hex"), str(call, "service_data_uuid"), str(call, "service_data_hex"),
                        flag(call, "connectable", true), call.params.containsKey("mode") ? str(call, "mode") : "balanced",
                        num(call, "seconds", 0));
                return;
            case "advertise_stop":
                core.advertiseStop(c);
                return;
            case "centrals":
                core.centrals(c);
                return;
            case "central_drop":
                core.centralDrop(c, str(call, "central"));
                return;
            case "keep_alive":
                core.keepAlive(c, flag(call, "enabled", false), false);
                return;
            default:
                calls.remove(c);
                reply.reply(ExtResult.error("not_registered", call.route));
        }
    }

    private void state(int c) {
        Map<String, Object> data = BleCore.obj("state", radio.adapterState(),
                "authorization", missingRuntime("central").isEmpty() && missingInstallTime("central") == null ? "granted" : "not_granted");
        data.putAll(core.stateFields());
        reply(c, true, null, null, data);
    }

    // ---- permissions ----------------------------------------------------------------------------

    private boolean has(String p) {
        return ContextCompat.checkSelfPermission(ctx.app(), p) == PackageManager.PERMISSION_GRANTED;
    }

    /** The first install-time permission the role needs and the build lacks, or null. */
    private String missingInstallTime(String role) {
        for (String p : BleCore.permissions(Build.VERSION.SDK_INT, role, false).get(0)) {
            if (!has(p)) return p;
        }
        return null;
    }

    /** The runtime permissions the role needs on this API level and that are not granted. */
    private List<String> missingRuntime(String role) {
        boolean never = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && scanNeverForLocation();
        List<String> missing = new ArrayList<>();
        for (String p : BleCore.permissions(Build.VERSION.SDK_INT, role, never).get(1)) {
            if (!has(p)) missing.add(p);
        }
        return missing;
    }

    /** API 31+: whether the app's manifest declares BLUETOOTH_SCAN with neverForLocation. */
    private boolean scanNeverForLocation() {
        try {
            Context app = ctx.app();
            PackageInfo info = app.getPackageManager().getPackageInfo(app.getPackageName(), PackageManager.GET_PERMISSIONS);
            if (info.requestedPermissions == null || info.requestedPermissionsFlags == null) return false;
            for (int i = 0; i < info.requestedPermissions.length; i++) {
                if (Manifest.permission.BLUETOOTH_SCAN.equals(info.requestedPermissions[i])) {
                    return (info.requestedPermissionsFlags[i] & PackageInfo.REQUESTED_PERMISSION_NEVER_FOR_LOCATION) != 0;
                }
            }
        } catch (PackageManager.NameNotFoundException | RuntimeException e) {
            ctx.log("permission flags unreadable: " + e.getClass().getSimpleName());
        }
        return false;
    }

    // ---- BleCore.Port: radio ------------------------------------------------------------------------

    @Override
    public String scanStart(int scan, List<String> services, boolean duplicates, String mode) {
        return radio.scanStart(scan, services, duplicates, mode);
    }

    @Override
    public void scanStop(int scan) {
        radio.scanStop(scan);
    }

    @Override
    public String connect(String id, int gen, boolean auto, boolean background) {
        return radio.connect(id, gen, auto, background);
    }

    @Override
    public boolean close(String id, int gen) {
        return radio.close(id, gen);
    }

    @Override
    public void release(String id, int gen) {
        radio.release(id, gen);
    }

    @Override
    public String op(String id, int gen, int op, String kind, String key, String descriptor, byte[] data, int arg) {
        return radio.op(id, gen, op, kind, key, descriptor, data, arg);
    }

    @Override
    public String serviceAdd(int epoch, String uuid, boolean primary, List<Map<String, Object>> chars) {
        return radio.serviceAdd(epoch, uuid, primary, chars);
    }

    @Override
    public void serviceRemove(String uuid) {
        radio.serviceRemove(uuid);
    }

    @Override
    public String advertiseStart(int epoch, int adv, Map<String, Object> params) {
        return radio.advertiseStart(epoch, adv, params);
    }

    @Override
    public void advertiseStop(int adv) {
        radio.advertiseStop(adv);
    }

    @Override
    public String notify(int epoch, int packet, String central, String key, byte[] data, boolean indicate) {
        return radio.notify(epoch, packet, central, key, data, indicate);
    }

    @Override
    public void centralDrop(String central) {
        radio.centralDrop(central);
    }

    /** The keep-alive service starts only while an activity is started (API 31 forbids a background start). */
    @Override
    public String keepAlive(boolean start, int hold) {
        return radio.keepAlive(start, hold, startedActivities > 0);
    }

    @Override
    public void persist(Map<String, Object> snapshot) {
        // iOS only: Android keeps no server file (the GATT server and advertising end with the process).
    }

    // ---- BleCore.Port: bridge -----------------------------------------------------------------------

    @Override
    public void timer(String kind, int token, long ms) {
        main.postDelayed(() -> core.timer(kind, token), ms);
    }

    @Override
    public void reply(int call, boolean ok, String code, String message, Map<String, Object> data) {
        Waiting w = calls.remove(call);
        if (w == null) return;
        try {
            w.reply.reply(ok ? ExtResult.ok(toJson(data)) : ExtResult.error(code, message));
        } catch (JSONException e) {
            w.reply.reply(ExtResult.error("handler_error", e.getMessage()));
        }
    }

    @Override
    public void emit(String event, Map<String, Object> data) {
        try {
            ctx.emit(event, toJson(data));
        } catch (JSONException e) {
            ctx.log("event " + event + " is not JSON: " + e.getMessage());
        }
    }

    @Override
    public boolean isActive(int call) {
        Waiting w = calls.get(call);
        return w != null && w.call.isActive();
    }

    @Override
    public long now() {
        return System.currentTimeMillis();
    }

    @Override
    public void stale(String what) {
        ctx.log("stale " + what);
    }

    @SuppressWarnings("unchecked")
    static Object json(Object v) throws JSONException {
        if (v instanceof Map) return toJson((Map<String, Object>) v);
        if (v instanceof List) {
            JSONArray a = new JSONArray();
            for (Object o : (List<Object>) v) a.put(json(o));
            return a;
        }
        return v == null ? JSONObject.NULL : v;
    }

    static JSONObject toJson(Map<String, Object> m) throws JSONException {
        JSONObject o = new JSONObject();
        if (m != null) for (Map.Entry<String, Object> e : m.entrySet()) o.put(e.getKey(), json(e.getValue()));
        return o;
    }
}
