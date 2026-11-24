# Bluetooth LE tests

## What runs without hardware

1. The shared core. `tests/vectors/ble_core.json` holds the rules both platforms share: links and their generations, the operation queue, write limits and chunking, permissions by Android API level and role, scan filters and options, the journal and the previous launch, the server table and notify queue, advertising and keep-alive. Each row runs against `BleCore.java` on the JVM and `BleCore.swift` with `swiftc`. Each named mutation must turn its scenario red, so the vectors keep guarding the rule:

   ```sh
   python3 -I tests/run.py jvm     # JDK 17 or later
   python3 -I tests/run.py swift   # macOS with Swift
   ```

2. The route contract. `tests/route/plan-ios.json` and `tests/route/plan-android.json` call each of the 32 routes once from a page in the built app. `tests/route/check_routes.py` checks every answer against the documented envelope, error codes and platform limits (see `tests/route/README.md`). The iOS simulator and the Android emulator have no Bluetooth peer, so this proves state, permission, a missing or unsupported radio, a device that is not connected, and the platform limits. It does not prove a radio.

3. A compile of both platforms in a V3 app with the extension included: the iOS simulator app and the Android Gradle variant.

## What needs two physical devices

Neither the simulator nor the emulator has a Bluetooth radio. Run these on real phones before you rely on a feature. Use one phone as the central (your app) and a second as the peripheral: a BLE test app such as nRF Connect, or this extension's own peripheral role on another phone.

1. **Permission.** Fresh install. Call `scan_start`. Check that the system asks for Bluetooth (iOS) or Nearby devices (Android 12 and later), or Location (Android 7 to 11). Deny it, and check `permission_denied`. Allow it, and check that the scan starts.
2. **Scan.** Advertise a known service UUID on the second phone. Scan with and without a `services` filter, with `names` and `manufacturer_id` filters, and with `duplicates`. Check `device` events (name, RSSI, advertisement data) and `scan_end` after `seconds`.
3. **Connect and discover.** `connect` with `seconds` 10, then with `seconds` 0 (no limit) while the peripheral is out of range, then bring it into range. Call `discover` and check the services, characteristics and descriptors against the peripheral's table.
4. **Read and write.** `read` a readable characteristic and a descriptor. `write` with `response` true and false, as `hex`, `b64` and `text`. Write more than the MTU allows without response, and check the chunks and `too_long`. Call `raw` and check that it writes to the first writable characteristic.
5. **Notify.** `subscribe` to a notifying and an indicating characteristic. Change the value on the peripheral and check `value` events. `unsubscribe` and check that they stop.
6. **MTU, RSSI, priority, PHY.** `mtu` with `size` 247 on Android (iOS answers `requested: false` with the negotiated size). `rssi` on both. On Android, `priority` with `level` high and `phy` with `tx` and `rx` `2m`; check the `phy` event. On iOS, check that `priority` and `phy` answer `platform_limit`.
7. **Bonding (Android).** `bond` a peripheral that requires encryption. Accept the system pairing dialog. Check the `bond` event and `bonds`. On iOS, read an encrypted characteristic and check that the system pairs. `bond` answers `platform_limit`.
8. **System devices and connection events.** Connect the peripheral from the system settings or another app. Check `system_devices` with its service, and the `connection_event` after `connection_events`.
9. **Background.** iOS: background the app with a link and a subscription, change the value, and check the `value` events in the journal (`events`) on return. Force a Bluetooth relaunch (keep a pending connect, terminate the app from Xcode, bring the peripheral into range) and check the `restored` event. Android: start `keep_alive` with the app visible, background it, and check that the link and notifications continue with the foreground notification shown.
10. **Peripheral role.** `service_add`, `advertise_start` with a name and a service, and connect from the second phone. Check `centrals`, `value_set`, `notify` to the subscribed central, and, on Android, `central_drop`.
11. **Server posts.** Set `server` on `connect` and `subscribe` to an HTTPS endpoint you own. Check the `ble_state` and `ble_data` posts. Go offline, change the value, come back online, and check that the queued posts arrive.
12. **The previous launch.** Change values, terminate the app, relaunch, and read `events` with `run=previous`.

Record the phone models, OS versions and the peripheral used with each result.
