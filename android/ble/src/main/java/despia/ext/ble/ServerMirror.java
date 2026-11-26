package despia.ext.ble;

import android.content.Context;
import android.os.BatteryManager;
import android.os.Handler;

import com.despia.nativeext.ExtContext;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * The {@code server} parameter of {@code connect} and {@code subscribe}: every link change of that
 * device is POSTed to the URL as {@code ble_state}, every notification of that characteristic as
 * {@code ble_data}, in every app state, in the bodies the retired core used. Posts wait in a queue
 * kept in the data directory (the newest 500, oldest dropped) and are sent one at a time; a failed
 * post is retried after 30 s and at the next launch, so nothing is lost to a dead network.
 *
 * <p>A URL is used only while the build's approved manifest still allows it for its route and
 * parameter ({@link ExtContext#isApprovedUrl}); one that does not is dropped with its posts.
 */
final class ServerMirror {
    static final int QUEUE_MAX = 500;
    static final long RETRY_MS = 30_000;
    static final int TIMEOUT_MS = 15_000;

    private final ExtContext ctx;
    private final Handler main;
    private final File file;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    /** Device id: the state URL (from connect). */
    private final Map<String, String> stateUrl = new HashMap<>();
    /** Device id + characteristic key: the data URL (from subscribe). */
    private final Map<String, String> dataUrl = new HashMap<>();
    private final Deque<JSONObject> queue = new ArrayDeque<>();
    private boolean sending;
    private boolean retryPosted;
    int dropped;

    ServerMirror(ExtContext ctx, Handler main) {
        this.ctx = ctx;
        this.main = main;
        File dir = new File(ctx.dataDir(), "ble");
        //noinspection ResultOfMethodCallIgnored
        dir.mkdirs();
        file = new File(dir, "server.json");
        load();
    }

    void watchState(String id, String url) {
        stateUrl.put(id, url);
        save();
    }

    void unwatchState(String id) {
        if (stateUrl.remove(id) != null) save();
    }

    void watchData(String id, String key, String url) {
        dataUrl.put(id + "|" + key, url);
        save();
    }

    void unwatchData(String id, String key) {
        if (dataUrl.remove(id + "|" + key) != null) save();
    }

    /** Called for every event the core emits. */
    void onEvent(String event, Map<String, Object> data, boolean background) {
        try {
            if ("link".equals(event)) {
                String id = (String) data.get("id");
                String url = stateUrl.get(id);
                if (url == null) return;
                JSONObject body = new JSONObject().put("event", "ble_state").put("deviceId", id)
                        .put("state", data.get("state")).put("timestamp", System.currentTimeMillis() / 1000.0)
                        .put("background", background).put("battery", battery());
                Object err = data.get("error");
                if (err instanceof Map) body.put("error", ((Map<?, ?>) err).get("message"));
                else if (!"connected".equals(data.get("state")) && data.get("reason") != null) body.put("reason", data.get("reason"));
                enqueue(url, "connect", body);
                // The page ended the link itself: its last state is posted, then the device is no longer watched.
                if ("disconnected".equals(data.get("state")) && "requested".equals(data.get("reason"))) unwatchState(id);
            } else if ("value".equals(event)) {
                String id = (String) data.get("id");
                String key = BleCore.key((String) data.get("service"), (Integer) data.get("service_n"),
                        (String) data.get("char"), (Integer) data.get("char_n"));
                String url = dataUrl.get(id + "|" + key);
                if (url == null) return;
                byte[] v = BleCore.fromHex((String) data.get("hex"));
                JSONObject body = new JSONObject().put("event", "ble_data").put("deviceId", id)
                        .put("service", data.get("service")).put("characteristic", data.get("char"))
                        .put("value", android.util.Base64.encodeToString(v == null ? new byte[0] : v, android.util.Base64.NO_WRAP))
                        .put("valueHex", ((String) data.get("hex")).toUpperCase(java.util.Locale.ROOT))
                        .put("timestamp", System.currentTimeMillis() / 1000.0).put("background", background)
                        .put("battery", battery());
                enqueue(url, "subscribe", body);
            }
        } catch (Exception e) {
            ctx.log("server mirror: " + e.getClass().getSimpleName());
        }
    }

    /** 0 to 100, or -1 when the platform does not report it (BatteryManager.BATTERY_PROPERTY_CAPACITY). */
    private int battery() {
        BatteryManager bm = (BatteryManager) ctx.app().getSystemService(Context.BATTERY_SERVICE);
        int v = bm == null ? Integer.MIN_VALUE : bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
        return v < 0 || v > 100 ? -1 : v;
    }

    private void enqueue(String url, String route, JSONObject body) throws Exception {
        queue.addLast(new JSONObject().put("url", url).put("route", route).put("body", body));
        while (queue.size() > QUEUE_MAX) {
            queue.removeFirst();
            dropped++;
        }
        save();
        pump();
    }

    /** Sends the oldest post; on success the next, on failure a retry in RETRY_MS. */
    void pump() {
        if (sending || queue.isEmpty()) return;
        JSONObject p = queue.peekFirst();
        String url = p.optString("url");
        if (!ctx.isApprovedUrl(url, p.optString("route"), "server")) {
            ctx.log("server mirror: a URL the build no longer approves was dropped");
            queue.removeFirst();
            save();
            pump();
            return;
        }
        sending = true;
        String body = p.optJSONObject("body").toString();
        io.execute(() -> {
            boolean ok = post(url, body);
            main.post(() -> {
                sending = false;
                if (ok) {
                    if (queue.peekFirst() == p) queue.removeFirst();
                    save();
                    pump();
                } else if (!retryPosted) {
                    retryPosted = true;
                    main.postDelayed(() -> {
                        retryPosted = false;
                        pump();
                    }, RETRY_MS);
                }
            });
        });
    }

    private static boolean post(String url, String body) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setRequestMethod("POST");
            c.setConnectTimeout(TIMEOUT_MS);
            c.setReadTimeout(TIMEOUT_MS);
            c.setInstanceFollowRedirects(false);
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "application/json");
            byte[] b = body.getBytes(StandardCharsets.UTF_8);
            c.setFixedLengthStreamingMode(b.length);
            try (OutputStream o = c.getOutputStream()) {
                o.write(b);
            }
            int code = c.getResponseCode();
            return code >= 200 && code < 300;
        } catch (Exception e) {
            return false;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private void save() {
        try {
            JSONObject o = new JSONObject();
            o.put("state", toJson(stateUrl));
            o.put("data", toJson(dataUrl));
            JSONArray q = new JSONArray();
            for (JSONObject p : queue) q.put(p);
            o.put("queue", q);
            byte[] b = o.toString().getBytes(StandardCharsets.UTF_8);
            File tmp = new File(file.getPath() + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(b);
                out.getFD().sync();
            }
            if (!tmp.renameTo(file)) ctx.log("server mirror: the queue file could not be replaced");
        } catch (Exception e) {
            ctx.log("server mirror: save " + e.getClass().getSimpleName());
        }
    }

    private static JSONObject toJson(Map<String, String> m) throws org.json.JSONException {
        JSONObject o = new JSONObject();
        for (Map.Entry<String, String> e : m.entrySet()) o.put(e.getKey(), e.getValue());
        return o;
    }

    private void load() {
        if (!file.exists()) return;
        try {
            JSONObject o = new JSONObject(readText(file));
            JSONObject st = o.optJSONObject("state");
            if (st != null) for (Iterator<String> it = st.keys(); it.hasNext(); ) {
                String k = it.next();
                stateUrl.put(k, st.optString(k));
            }
            JSONObject da = o.optJSONObject("data");
            if (da != null) for (Iterator<String> it = da.keys(); it.hasNext(); ) {
                String k = it.next();
                dataUrl.put(k, da.optString(k));
            }
            Object q = o.opt("queue");
            if (q instanceof JSONArray) {
                JSONArray a = (JSONArray) q;
                for (int i = 0; i < a.length(); i++) {
                    if (a.opt(i) instanceof JSONObject) queue.addLast((JSONObject) a.opt(i));
                }
            }
        } catch (Exception e) {
            ctx.log("server mirror: the queue file is unreadable and was reset");
        }
    }

    /** A whole file as UTF-8 (API 24: no java.nio.file). */
    static String readText(File f) throws java.io.IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[8192];
            for (int n; (n = in.read(b)) > 0; ) out.write(b, 0, n);
        }
        return new String(out.toByteArray(), StandardCharsets.UTF_8);
    }

    /** What the {@code state} route reports. */
    Map<String, Object> status() {
        return BleCore.obj("servers", stateUrl.size() + dataUrl.size(), "pending", queue.size(), "dropped", dropped);
    }
}
