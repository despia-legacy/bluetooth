# Bluetooth LE

Source preview for Despia V3. This snapshot requires the runtime update currently awaiting release and an approved extension-enabled native build. Uploading these files does not change an installed app.

Bluetooth Low Energy as central and peripheral on iOS and Android.

This ready-made extension is part of Despia V3 Extensions. First-party V4 support comes through the new package registry, with a different package shape.

Bluetooth central support is pending device validation.

[V3 extension documentation](https://setup.despia.com/experiments/v3-extensions) and [extension skill](https://github.com/despia-legacy/extension-skill).

## Web frameworks and app builders

Use the Despia SDK with React, Vue, Svelte, Next.js, TanStack or HTML5. Projects built with Lovable, Base44, Replit and other app builders need custom JavaScript and static file hosting. Claude Code, Codex and Cursor can edit the same extension files.

## What is included

- `manifest.json`: the extension's routes, parameters, events and native files.
- `ios/` and `android/`: the Swift and Kotlin or Java sources and resources the manifest names.
- `extensions.example.json`: the entry for `public/despia/extensions.json`.
- `ble.policy.json`: an empty policy example. No additional approval fields are needed by this fixture. A policy example is not an approval.

## Requirements

- A Despia V3 app with V3 Extensions enabled, and a web app that serves static files from its own HTTPS origin.
- The `despia-native` JavaScript SDK (`npm install despia-native`).
- A physical device. Bluetooth does not run in the iOS simulator.
- The two AndroidX libraries named below must be the versions your app's base build already resolves.

## Install

1. Copy `manifest.json`, `ios/` and `android/` into `public/despia/ble/` in your web app. The folder name is the extension id, so pages call `extension://ble/<route>`. Keep every path inside the folder unchanged, because the manifest names them. (`public/` is the folder your site serves from its root; in SvelteKit, use `static/`.)
2. Add `"ble"` to the `extensions` list in `public/despia/extensions.json`. `extensions.example.json` shows the entry. Despia takes app identity from the build configuration.
3. Set the values listed under "Values to set before you build". Vendor keys and hosts in this repository are placeholders only. Never put a server secret in the manifest or anywhere in your web app.
4. Request approval and a new native build in Despia. Despia reviews and approves these exact files before a build includes them, and any change to the manifest or to a native file needs a new approval and a new native build. It cannot be applied over the air.

## JavaScript SDK

Install the SDK in your web app:

```sh
npm install despia-native
```

Copy `example/src/lib/despia-extension.js` to your app's `src/lib/` and adjust the import path if needed. It imports `despia` from `despia-native`, calls the SDK and returns the native answer's `data`. It checks native error envelopes and throws an error with their `code`. The SDK itself resolves native `ok: false` envelopes; it does not reject them. A single watched value becomes `undefined` after 30 seconds, which this helper reports as `sdk_timeout`.

Each helper call forwards a unique native callback into a separate watched value, so overlapping calls do not share response globals. `onExtensionEvent` registers the declared native event callbacks and returns a cleanup function. Events are callbacks, not values you can poll from the SDK proxy.

Importing the SDK is safe during server rendering. Run calls and event subscriptions only from browser click handlers or mounted client hooks. React and Vue can use the browser APIs used by this helper; in Next.js and other server-rendered apps, keep these calls in client code. The extension must be included in the installed Despia V3 app; a browser preview has no native extension features.

## Calling it

```javascript
import { extensionCall } from './lib/despia-extension.js';

const answer = await extensionCall('ble', 'state');
console.log(answer);
```

Calls use `extension://ble/<route>?<params>`. Each route answers once, in the page that made the call: the runtime sets the route's answer variable in the page, then calls the route's callback. Only declared parameters are accepted. Keep large data on the native side and pass identifiers through the bridge. A call URL is at most 8192 characters.

Every answer has the same shape: `ok`, `provider`, `platform`, `runtime` (`3`), `bridge` (`1`), `extension`, `route`, `data` (your handler's data on success, `null` on error), and on error `error` (a message) and `code`.

Standard error codes: `bad_request` (an undeclared or missing parameter, or a value of the wrong type), `not_registered` (this build does not contain the extension or route), `forbidden_frame` (the call did not come from the top-level page), `forbidden_origin` (an origin that is not allowed), `rate_limited` (more than 20 calls per second to one extension), `timeout` (no answer within the route's `timeout_ms`), `unavailable`, `platform_limit` (this platform or OS version has no such capability), `handler_error`, plus the codes this extension lists below.

---

## About

This extension gives your web app Bluetooth Low Energy operations on iOS (CoreBluetooth) and Android (`android.bluetooth`), in both roles:

- **Central:** scan, connect, discover services, read, write, subscribe to notifications, read RSSI and set the MTU.
- **Peripheral:** publish your own GATT services, answer reads from a value store, receive writes, send notifications, and advertise.

Bytes cross the bridge as lower-case `hex` (or `b64` in parameters). No native object ever reaches the page.

---

## Values to set before you build

Despia takes app identity from the existing build configuration. `public/` is the folder your site serves from its root (in SvelteKit, write `static/`). The paths must stay as written, because the manifest names them. Despia reviews and approves these exact files before a build includes them.

In Despia, turn on the Bluetooth purpose string (`NSBluetoothAlwaysUsageDescription`) and write the sentence your users see in the permission prompt (iOS), and turn on nearby devices, which grants `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` and `BLUETOOTH_ADVERTISE` on Android 12 and later (Android). The Bluetooth background modes come from the manifest. The two AndroidX libraries must be the versions your app's base build already resolves. The build refuses others.

---

## Permissions and capabilities

### iOS

- **Bluetooth.** `NSBluetoothAlwaysUsageDescription`, declared under `requires.usage_descriptions`. Set the purpose text in Despia. Call `state` with `prompt=true` to show the system prompt. Without `prompt`, `state` never shows it.
- **Background modes.** `bluetooth-central` and `bluetooth-peripheral`.
- **State restoration.** The `bluetooth_restoration` lifecycle hook and the central restore identifier `main`. When iOS relaunches the app for Bluetooth, kept links come back and the `restored` event fires.

### Android

- **Nearby devices and location.** `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` and `ACCESS_FINE_LOCATION`, declared under `requires.permissions`. Turn these permissions on for your app in Despia. The extension asks for the ones a route needs at runtime, one request at a time. On Android 12 (API 31) and later a scan needs `BLUETOOTH_SCAN`, a link needs `BLUETOOTH_CONNECT`, and advertising needs `BLUETOOTH_ADVERTISE`. On Android 7 to 11 (API 24 to 30) a scan needs `ACCESS_FINE_LOCATION`.
- **Legacy grants.** The module's `AndroidManifest.xml` adds `BLUETOOTH` and `BLUETOOTH_ADMIN` up to API 30.
- **Keep-alive.** `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE`, for the `connectedDevice` foreground service that keeps links alive while the app is in the background. It starts only from `keep_alive`, while the app is visible.
- **Libraries.** `androidx.core:core:1.18.0` and `androidx.activity:activity:1.13.0`.

---

## Using it from your web app

Every route answers once in its own variable and callback, `ble<Route>` and `onBle<Route>`, for example `bleScanStart` and `onBleScanStart`. Events arrive on their own callbacks. Define the event callbacks before you call a route.

### Central

```javascript
import { extensionCall, onExtensionEvent } from './lib/despia-extension.js';
const ble = (route, params) => extensionCall('ble', route, params);
const HEART_RATE = '180d';
const MEASUREMENT = '2a37';

const stopDevices = onExtensionEvent('onBleDevice', event => {
  event.devices.forEach(device => console.log(device.id, device.name, device.rssi));
});
const stopValues = onExtensionEvent('onBleValue', event => {
  event.records.forEach(record => console.log(record.char, record.hex));
});
export async function startScan() {
  const state = await ble('state', { prompt: true });
  if (state.state !== 'on') throw new Error(state.state);
  await ble('scan_start', { services: HEART_RATE, seconds: 10 });
}
export async function connectDevice(id) {
  await ble('scan_stop');
  await ble('connect', { id, auto: true });
  await ble('discover', { id });
  await ble('subscribe', { id, service: HEART_RATE, char: MEASUREMENT });
}
// Run startScan() from a click, then pass a discovered device's id to connectDevice(id).
// Read or write only characteristics your device exposes:
// const battery = await ble('read', { id, service: '180f', char: '2a19' });
// await ble('write', { id, service: 'fff0', char: 'fff1', hex: '0102' });
// Later: await ble('disconnect', { id }); stopDevices(); stopValues();
```

### Peripheral

```javascript
import { extensionCall, onExtensionEvent } from './lib/despia-extension.js';
const ble = (route, params) => extensionCall('ble', route, params);
const SERVICE = '0000fff0-0000-1000-8000-00805f9b34fb';
const STATUS = '0000fff1-0000-1000-8000-00805f9b34fb';
const COMMAND = '0000fff2-0000-1000-8000-00805f9b34fb';
const stopRequests = onExtensionEvent('onBleRequest', event => {
  event.records.forEach(record => console.log(record.central, record.char, record.hex));
});
await ble('state', { prompt: true });
await ble('service_add', { uuid: SERVICE, chars: `${STATUS}~rn~00,${COMMAND}~w` });
await ble('value_set', { service: SERVICE, char: STATUS, hex: '01' });
const advertising = await ble('advertise_start', { services: SERVICE, name: 'My Device', seconds: 300 });
console.log(advertising.applied);
await ble('notify', { service: SERVICE, char: STATUS, hex: '02' });
// Later: await ble('advertise_stop'); await ble('service_remove'); stopRequests();
```

### Missed events

Every event is also kept in a journal of up to 2000 records, each with a `seq`. A page that was not loaded when something happened reads it back:

```javascript
let after = 0;
const journal = await extensionCall('ble', 'events', { after, max: 200 });
for (const record of journal.records) console.log(record);
after = journal.next;
```

Ask for Bluetooth first: call `state` with `prompt=true` before the first scan, connect or server route, so the system prompt is answered before anything waits on it. A route that waited too long answers `timeout` and started nothing. Call it again. A `connect` to a device that is already connecting (for example one iOS brought back after your app relaunched) joins that attempt and resolves with its result.

### Routes

**Central**

| Route         | Parameters                                                                              | Answer `data`                                    | Answer variable | Callback |
| ------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------ | --- | --- |
| `state`       | `prompt`                                                                                | `state`, `authorization`, `scanning`, `advertising`, `links`, `centrals`, `keepAlive`, `epoch`, `run` | `bleState` | `onBleState` |
| `events`      | `after` (0 or more), `max` (1 to 200)                                                   | `records`, `next`, `dropped`, `run`              | `bleEvents` | `onBleEvents` |
| `scan_start`  | `services` (comma-separated, up to 20), `seconds` (0 to 3600, 0 until `scan_stop`), `duplicates`, `mode` | `scan`                          | `bleScanStart` | `onBleScanStart` |
| `scan_stop`   | none                                                                                    | `scan`, `stopped`                                | `bleScanStop` | `onBleScanStop` |
| `devices`     | none                                                                                    | `devices` (up to 200)                            | `bleDevices` | `onBleDevices` |
| `connect`     | `id` (required), `auto`, `seconds` (1 to 20, default 10)                                 | `id`, `link`, `state`, `mtu`                     | `bleConnect` | `onBleConnect` |
| `disconnect`  | `id` (required)                                                                         | `id`, `state`, `confirmed`                       | `bleDisconnect` | `onBleDisconnect` |
| `links`       | none                                                                                    | `links`                                          | `bleLinks` | `onBleLinks` |
| `discover`    | `id` (required)                                                                         | `id`, `services`                                 | `bleDiscover` | `onBleDiscover` |
| `read`        | `id`, `service`, `char` (required), `service_n`, `char_n`, `descriptor`                  | `hex`                                            | `bleRead` | `onBleRead` |
| `write`       | as `read`, plus `hex` or `b64`, `response` (default `true`)                              | `written`, `chunks`                              | `bleWrite` | `onBleWrite` |
| `subscribe`, `unsubscribe` | `id`, `service`, `char` (required), `service_n`, `char_n`                  | `subscribed`, `mode`                             | `bleSubscribe`, `bleUnsubscribe` | `onBleSubscribe`, `onBleUnsubscribe` |
| `rssi`        | `id` (required)                                                                         | `rssi`                                           | `bleRssi` | `onBleRssi` |
| `mtu`         | `id` (required), `size` (23 to 517)                                                     | `mtu`, `writeMax`, `writeNoResponseMax`, `requested` | `bleMtu` | `onBleMtu` |

**Peripheral**

| Route             | Parameters                                                                     | Answer `data`                       | Answer variable | Callback |
| ----------------- | ------------------------------------------------------------------------------ | ----------------------------------- | --- | --- |
| `service_add`     | `uuid` (required), `primary` (default `true`), `chars`                         | `uuid`, `characteristics`           | `bleServiceAdd` | `onBleServiceAdd` |
| `service_remove`  | `uuid`; without it, every service                                              | `removed`                           | `bleServiceRemove` | `onBleServiceRemove` |
| `services`        | none                                                                           | `services`, `advertising`           | `bleServices` | `onBleServices` |
| `value_set`       | `service`, `char` (required), `char_n`, `hex` or `b64` (up to 512 bytes)        | `bytes`                             | `bleValueSet` | `onBleValueSet` |
| `notify`          | as `value_set`, plus `central` (one central; without it, every subscribed one) | `sent`, `subscribers`               | `bleNotify` | `onBleNotify` |
| `advertise_start` | `services`, `name` (up to 26), `manufacturer_id` with `manufacturer_hex`, `service_data_uuid` with `service_data_hex`, `connectable` (default `true`), `mode`, `seconds` (0 to 3600) | `advertising`, `applied` | `bleAdvertiseStart` | `onBleAdvertiseStart` |
| `advertise_stop`  | none                                                                           | `advertising`                       | `bleAdvertiseStop` | `onBleAdvertiseStop` |
| `centrals`        | none                                                                           | `centrals`                          | `bleCentrals` | `onBleCentrals` |
| `central_drop`    | `central` (required)                                                           | `dropped`                           | `bleCentralDrop` | `onBleCentralDrop` |
| `keep_alive`      | `enabled` (required)                                                           | `enabled`, `active`, `reason`       | `bleKeepAlive` | `onBleKeepAlive` |

`mode` is `low_power`, `balanced` or `low_latency`. A device `id` is the iOS peripheral identifier or the Android MAC address. UUIDs can be 16, 32 or 128 bit in any case; answers always use lower-case 128-bit. `service_n` and `char_n` number equal UUIDs in discovery order.

### Events

| Event           | Callback            | Scope      | When                                                         |
| --------------- | ------------------- | ---------- | ------------------------------------------------------------ |
| `adapter`       | `onBleAdapter`      | `app`      | Bluetooth turned on or off                                   |
| `restored`      | `onBleRestored`     | `app`      | iOS restored the Bluetooth state after a relaunch            |
| `device`        | `onBleDevice`       | `document` | Devices found by a scan, batched every 50 ms                 |
| `scan_end`      | `onBleScanEnd`      | `document` | A scan ended                                                 |
| `link`          | `onBleLink`         | `document` | A link connected, is reconnecting, or disconnected           |
| `value`         | `onBleValue`        | `document` | Notified values, batched every 50 ms                         |
| `gatt_changed`  | `onBleGattChanged`  | `document` | A device changed its services                                |
| `central`       | `onBleCentral`      | `document` | A central connected, disconnected, subscribed or unsubscribed |
| `request`       | `onBleRequest`      | `document` | Writes from centrals, batched                                |
| `advertise_end` | `onBleAdvertiseEnd` | `document` | Advertising stopped, elapsed, lost the adapter, or failed    |

`restored` carries `peripherals` and `scanning` for the central role, and `services`, `advertising` and `lost` for the server role. Every event is also a journal record, so a page that was not loaded when it happened reads it with `events`. `device` and `value` are batched every 50 ms.

### Error codes

A failed `connect` answers `connect_failed`. Its message and the `link` event carry the platform's own error: `error: {domain, code, message, name}`, the CoreBluetooth error on iOS and the GATT status on Android. A known code also gives a readable `reason`, such as `encryption_timeout`.

Besides the standard codes: `busy`, `unavailable`, `permission_denied`, `scan_failed`, `bad_value`, `unknown_device`, `not_connected`, `not_found`, `not_permitted`, `too_long`, `connect_failed`, `connect_timeout`, `gatt_error`, `link_lost`, `filter_required` (a scan in the background needs a service filter), `advertise_failed`, `no_subscribers` and `platform_limit` (this platform has no such API; the message names it).

---

## Platform limits

- **iOS.** No scan `mode` and no MTU request (`mtu` answers `requested: false`). No API to drop a central (`central_drop` answers `platform_limit`). An advertisement carries only service UUIDs and a local name, is always connectable, and in the background carries no name. In the background, a scan without a service filter is stopped, and a new one answers `filter_required`.
- **iOS, reads.** A characteristic value and a read answer arrive through the same callback, so a notification that lands while a read of the same characteristic is in flight answers that read.
- **Android.** No state restoration: links, the server and advertising end with the app's process. Use `keep_alive` to keep links while the app is in the background. With `name`, Android advertises the device's own Bluetooth name. A controller without advertising support answers `platform_limit`.
- **Both.** One GATT operation runs at a time per link, up to 64 wait, and each has a 10 second timeout that closes the link. Writes are at most 512 bytes. A write without response means the bytes were handed to the system, not that they were delivered.

## License

[Despia V3 Extension Source-Available Commercial License](LICENSE).
You may inspect the source. Using or modifying this extension requires a valid
Despia commercial license and a valid Despia project for the particular app.
The standard price is **USD 249 per application per operating system**.
iOS and Android require separate licenses. See [Despia](https://despia.com).
Third-party SDKs keep their own licenses. Experimental V3 extensions do not
include a commitment to maintenance or a V4 port.

## Source and licensing

Browse, clone or fork this source to inspect it. Public GitHub forks remain public. For private development, clone into a private workspace or private repository. Modification, building, execution and deployment require a valid Despia commercial license and a valid Despia project for the application. The standard price is USD 249 per application per operating system. Licensed users may customize the extension or use it as a reference for new functionality in that licensed app. Keep the license and applicable notices. See [LICENSE](LICENSE) for the terms.
