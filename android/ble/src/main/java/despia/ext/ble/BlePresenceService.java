package despia.ext.ble;

import android.annotation.TargetApi;
import android.companion.AssociationInfo;
import android.companion.CompanionDeviceService;
import android.companion.DevicePresenceEvent;
import android.os.Build;

/**
 * The system binds this service when an observed associated device appears, disappears, connects or
 * disconnects, and starts the process for it (CompanionDeviceService, API 31; read 2026-11-25:
 * https://developer.android.com/reference/android/companion/CompanionDeviceService). API 36 calls
 * onDevicePresenceEvent; API 33 to 35 the AssociationInfo forms; API 31 and 32 the address forms. Each
 * form answers only on the levels that call it, so one change is one {@code presence} event.
 */
@TargetApi(31) // Bound only by the system of API 31 and later (CompanionDeviceService).
public final class BlePresenceService extends CompanionDeviceService {

    private static void deliver(int association, String address, String event) {
        BleExtension ext = BleExtension.instance;
        if (ext != null) ext.presenceEvent(association, address, event);
    }

    @TargetApi(36)
    @Override
    public void onDevicePresenceEvent(DevicePresenceEvent e) {
        String event;
        switch (e.getEvent()) {
            case DevicePresenceEvent.EVENT_BLE_APPEARED:
                event = "appeared";
                break;
            case DevicePresenceEvent.EVENT_BLE_DISAPPEARED:
                event = "disappeared";
                break;
            case DevicePresenceEvent.EVENT_BT_CONNECTED:
                event = "connected";
                break;
            case DevicePresenceEvent.EVENT_BT_DISCONNECTED:
                event = "disconnected";
                break;
            default:
                event = "event " + e.getEvent();
        }
        BleExtension ext = BleExtension.instance;
        deliver(e.getAssociationId(), ext == null ? null : ext.addressOf(e.getAssociationId()), event);
    }

    @TargetApi(33)
    @Override
    @SuppressWarnings("deprecation")
    public void onDeviceAppeared(AssociationInfo info) {
        if (Build.VERSION.SDK_INT >= 36) return;
        deliver(info.getId(), info.getDeviceMacAddress() == null ? null : BleRestore.mac(info.getDeviceMacAddress()), "appeared");
    }

    @TargetApi(33)
    @Override
    @SuppressWarnings("deprecation")
    public void onDeviceDisappeared(AssociationInfo info) {
        if (Build.VERSION.SDK_INT >= 36) return;
        deliver(info.getId(), info.getDeviceMacAddress() == null ? null : BleRestore.mac(info.getDeviceMacAddress()), "disappeared");
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onDeviceAppeared(String address) {
        if (Build.VERSION.SDK_INT >= 33) return;
        BleExtension ext = BleExtension.instance;
        deliver(ext == null ? 0 : ext.idForAddress(address), address, "appeared");
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onDeviceDisappeared(String address) {
        if (Build.VERSION.SDK_INT >= 33) return;
        BleExtension ext = BleExtension.instance;
        deliver(ext == null ? 0 : ext.idForAddress(address), address, "disappeared");
    }
}
