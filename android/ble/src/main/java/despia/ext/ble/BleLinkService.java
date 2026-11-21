package despia.ext.ble;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * Keeps the process alive while the page asked for it ({@code keep_alive?enabled=true}) and a link,
 * a remote central or advertising exists. It decides nothing: {@link BleCore#holdCurrent} says
 * whether a start is still wanted. Started only by {@link AndroidRadio#keepAlive} while an activity
 * is started; never at launch, never sticky.
 *
 * <p>Every start enters the foreground first (the platform's obligation after
 * {@code startForegroundService}), then a start whose hold generation is no longer current stops
 * with {@code stopSelfResult} of its own start id, so an older start never ends a newer one. There is
 * no unqualified {@code stopSelf()}.
 */
public final class BleLinkService extends Service {
    static final String EXTRA_HOLD = "despia.ext.ble.hold";
    static final String CHANNEL = "nativeext.ble.link";
    static final int NOTIFICATION = 0x0B1E;

    /** The core of the running extension (set when it is created; main thread only). */
    static BleCore core;
    private static BleLinkService running;
    private int lastStartId;

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        lastStartId = startId;
        running = this;
        if (!enterForeground()) {
            leave(startId);
            return START_NOT_STICKY;
        }
        int g = intent == null ? -1 : intent.getIntExtra(EXTRA_HOLD, -1);
        BleCore c = core;
        if (c == null || !c.holdCurrent(g)) leave(startId);
        // A restart with a null intent would show the notification for links that no longer exist.
        return START_NOT_STICKY;
    }

    /** Ends the service for the newest start; called when the core's hold ends. */
    static void release() {
        BleLinkService s = running;
        if (s != null) s.leave(s.lastStartId);
    }

    private void leave(int startId) {
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelfResult(startId);
    }

    @Override
    public void onDestroy() {
        if (running == this) running = null;
        super.onDestroy();
    }

    private String text(String name, String fallback) {
        int id = getResources().getIdentifier(name, "string", getPackageName());
        return id == 0 ? fallback : getString(id);
    }

    @SuppressWarnings("deprecation")
    private boolean enterForeground() {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationManager nm = getSystemService(NotificationManager.class);
            if (nm != null) {
                nm.createNotificationChannel(new NotificationChannel(CHANNEL,
                        text("nx_ble_channel_name", "Bluetooth connections"), NotificationManager.IMPORTANCE_LOW));
            }
            b = new Notification.Builder(this, CHANNEL);
        } else {
            b = new Notification.Builder(this).setPriority(Notification.PRIORITY_LOW);
        }
        b.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
                .setContentTitle(text("nx_ble_link_title", "Bluetooth"))
                .setContentText(text("nx_ble_link_text", "Keeping Bluetooth devices connected"))
                .setOngoing(true);
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) b.setContentIntent(PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE));
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION, b.build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);
            } else {
                startForeground(NOTIFICATION, b.build());
            }
            return true;
        } catch (RuntimeException e) {
            // API 34: SecurityException without the connected-device grant; API 31:
            // ForegroundServiceStartNotAllowedException. Links go on while the process lives.
            Log.w("nativeext.ble", "keep-alive could not enter the foreground: " + e.getClass().getSimpleName());
            return false;
        }
    }
}
