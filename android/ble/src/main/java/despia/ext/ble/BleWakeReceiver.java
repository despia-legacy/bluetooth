package despia.ext.ble;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Handler;
import android.os.Looper;

/**
 * The wake scan's PendingIntent target (BluetoothLeScanner.startScan with a PendingIntent, API 26; read
 * 2026-11-25). The system starts the process for it; the extension was created in Application.onCreate
 * first, so its core is there. Not exported: only this app's PendingIntent reaches it.
 */
public final class BleWakeReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !BleRestore.WAKE_ACTION.equals(intent.getAction())) return;
        BleExtension ext = BleExtension.instance;
        if (ext == null) return;
        int error = BleRestore.wakeError(intent);
        ext.wakeDelivered(error > 0 ? new java.util.ArrayList<>() : BleRestore.wakeDevices(intent), error);
        // Keep the receiver alive until the journal write (BleExtension.PERSIST_MS) has run.
        PendingResult result = goAsync();
        new Handler(Looper.getMainLooper()).postDelayed(result::finish, BleExtension.PERSIST_MS + 250);
    }
}
