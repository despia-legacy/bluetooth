# Bluetooth LE

Source preview for Despia V3. The runtime update and automatic discovery rollout are awaiting release. Rebuild and install the native app to include these files; uploading them does not change an installed app.

Bluetooth Low Energy as central and peripheral on iOS and Android.

This ready-made extension is part of Despia V3 Extensions. First-party V4 support comes through the new package registry, with a different package shape.

Bluetooth central and peripheral support is pending validation on physical devices. Route answers for state, permission and an unavailable radio are proven in the iOS simulator and the Android emulator; neither has a Bluetooth radio.

[V3 extension documentation](https://setup.despia.com/experiments/v3-extensions) and [extension skill](https://github.com/despia-legacy/extension-skill).

## Web frameworks and app builders

Use the Despia SDK with React, Vue, Svelte, Next.js, TanStack or HTML5. Projects built with Lovable, Base44, Replit and other app builders need custom JavaScript and static file hosting. Claude Code, Codex and Cursor can edit the same extension files.

## What is included

- `manifest.json`: the extension's routes, parameters, events and native files.
- `ios/` and `android/`: the Swift and Kotlin or Java sources and resources the manifest names.
- `extensions.example.json`: the entry for `public/despia/extensions.json`.
- `ble.policy.json`: an empty build-policy example. Keep it outside the hosted extension folder.

## Requirements

- A Despia V3 app and a web app that serves static files from its own HTTPS origin.
- The `despia-native` JavaScript SDK (`npm install despia-native`).
- A physical device. Bluetooth does not run in the iOS simulator.
- Android dependencies `androidx.core:core:1.18.0` and `androidx.activity:activity:1.13.0`, declared by the extension module. The native build must resolve and verify the app's dependency graph before compilation.

## Install

1. Copy `manifest.json`, `ios/` and `android/` into `public/despia/ble/` in your web app. The folder name is the extension id, so pages call `extension://ble/<route>`. Keep every path inside the folder unchanged, because the manifest names them. (`public/` is the folder your site serves from its root; in SvelteKit, use `static/`.)
2. Add `"ble"` to the `extensions` list in `public/despia/extensions.json`. `extensions.example.json` shows the entry. Despia takes app identity from the build configuration.
3. Set the values listed under "Values to set before you build". Vendor keys and hosts in this repository are placeholders only. Never put a server secret in the manifest or anywhere in your web app.
4. Rebuild and install the native app with these extension files. Any change to the manifest or native source requires another native build. It cannot be applied over the air.

Signed build verification binds source hashes, dependency pins, app identity and final artifacts. It is separate from human code review and does not require a per-app enrollment switch.

## JavaScript SDK

Install the SDK in your web app:

```sh
npm install despia-native
```

Call the published SDK directly and watch the exact answer variable declared in `manifest.json`. The SDK resolves to an object keyed by that variable; the native envelope is inside it. Check both a missing reply and `ok: false` before using `data`. Native errors resolve through the SDK; they do not reject its promise. A single watched variable becomes `undefined` after 30 seconds without a reply.

Await calls that use the same answer variable sequentially. The SDK's command queue does not correlate concurrent responses. Encode every query value with `encodeURIComponent`, including JSON text. Spaces become `%20`; a literal plus becomes `%2B`. Do not use unmodified `URLSearchParams` form encoding, which uses plus for spaces.

Importing the SDK is safe during server rendering. Run native calls only in browser click handlers or mounted client hooks, including client components in Next.js. The extension must be included in the installed Despia V3 app; a browser preview has no native extension features. Optional event handlers use the declared callback on `globalThis`, not an SDK subscription API. Save and restore any callback your app already owns when a component mounts and unmounts.

## Calling it

```javascript
import despia from 'despia-native';

const answerReply = await despia('extension://ble/state', ['bleState']);
const answer = answerReply.bleState;
if (answer === undefined) throw new Error('No native reply within 30 seconds');
if (!answer.ok) throw new Error(answer.code + ': ' + answer.error);

console.log(answer.data);
```

Calls use `extension://ble/<route>?<params>`. Each route answers once, in the page that made the call: the runtime sets the route's answer variable in the page, then calls the route's callback. Only declared parameters are accepted. Keep large data on the native side and pass identifiers through the bridge. A call URL is at most 8192 characters.

Every answer has the same shape: `ok`, `provider`, `platform`, `runtime` (`3`), `bridge` (`1`), `extension`, `route`, `data` (your handler's data on success, `null` on error), and on error `error` (a message) and `code`.

Standard error codes: `bad_request` (an undeclared or missing parameter, or a value of the wrong type), `not_registered` (this build does not contain the extension or route), `forbidden_frame` (the call did not come from the top-level page), `forbidden_origin` (an origin that is not allowed), `rate_limited` (more than 20 calls per second to one extension), `timeout` (no answer within the route's `timeout_ms`), `unavailable`, `platform_limit` (this platform or OS version has no such capability), `handler_error`, plus the codes this extension lists below.

---

## About

This extension gives your web app Bluetooth Low Energy operations on iOS (CoreBluetooth) and Android (`android.bluetooth`), in both roles:

- **Central:** scan with service, name and manufacturer filters, connect, discover services, read and write characteristics and descriptors (with and without response), subscribe to notifications and indications, read RSSI, set the MTU, set the connection priority and the PHY, bond, list bonded and system-connected devices, and watch connections the system makes.
- **Peripheral:** publish your own GATT services, answer reads from a value store, receive writes, send notifications, and advertise.
- **Server posts:** `connect` and `subscribe` can post every link change and every notified value to your HTTPS server, in every app state, from a queue that survives a restart.
- **Journal:** every event is kept on disk, so a page reads what happened while it was not loaded, including during the previous launch.

Bytes cross the bridge as lower-case `hex` (or `b64` in parameters). No native object ever reaches the page.

---

## Values to set before you build

Despia takes app identity from the existing build configuration. `public/` is the folder your site serves from its root (in SvelteKit, write `static/`). The paths must stay as written, because the manifest names them. Signed build verification checks the exact files included in the native build.

Replace the placeholder host `api.example.com` in the `server` parameters of `connect` and `subscribe` in `manifest.json` with the host of the server that receives the posts, or remove those two `server` parameters if you do not use them. A URL on any other host is refused with `bad_request`.

Supply `NSBluetoothAlwaysUsageDescription` with text explaining your app's Bluetooth use. Use the app's existing purpose-description configuration, or, with the upcoming runtime, add a nonempty string under `ios.app.info_plist` and set `ios.app.custom_keys` to `true`. Existing nonempty app-configured text takes priority. On Android, turn on the app's Bluetooth permission (the `bluetooth_always` key in the app's permissions) and Location (`location_when_in_use`): with the upcoming runtime, these declare the permissions required below in the final Android manifest. These declarations do not grant runtime access: the user decides when Android presents the permission request. The Bluetooth background modes come from the manifest. The Android module declares the two AndroidX dependencies listed below. The app's dependency build verification must include their resolved versions.

---

## Permissions and capabilities

### iOS

- **Bluetooth.** `NSBluetoothAlwaysUsageDescription`, declared under `requires.usage_descriptions`. Supply its purpose text as described above. Call `state` with `prompt=true` to show the system prompt. Without `prompt`, `state` never shows it.
- **Background modes.** `bluetooth-central` and `bluetooth-peripheral`.
- **State restoration.** The `bluetooth_restoration` lifecycle hook and the central restore identifier `main`. When iOS relaunches the app for Bluetooth, kept links come back and the `restored` event fires.

### Android

- **Nearby devices and location.** `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE` and `ACCESS_FINE_LOCATION`, required under `requires.permissions`. They must be declared in the final Android manifest: the app's Bluetooth permission (`bluetooth_always`) declares the three Bluetooth grants, and its Location permission (`location_when_in_use`) declares `ACCESS_FINE_LOCATION`. A declaration does not grant runtime consent. The extension requests the permissions a route needs, one request at a time, and handles the user's decision. On Android 12 (API 31) and later a scan needs `BLUETOOTH_SCAN` and also `ACCESS_FINE_LOCATION` unless the app declares `neverForLocation`; a link needs `BLUETOOTH_CONNECT`; advertising needs `BLUETOOTH_ADVERTISE` and `BLUETOOTH_CONNECT`. On Android 7 to 11 (API 24 to 30) a scan needs `ACCESS_FINE_LOCATION`.
- **Legacy grants.** The module's `AndroidManifest.xml` adds `BLUETOOTH` and `BLUETOOTH_ADMIN` up to API 30.
- **Keep-alive.** `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE`, for the `connectedDevice` foreground service that keeps links alive while the app is in the background. It starts only from `keep_alive`, while the app is visible.
- **Libraries.** `androidx.core:core:1.18.0` and `androidx.activity:activity:1.13.0`.

---

## Using it from your web app

Every route answers once in its own variable and callback, `ble<Route>` and `onBle<Route>`, for example `bleScanStart` and `onBleScanStart`. Events arrive on their own callbacks. Define the event callbacks before you call a route.

### Central

```javascript
import despia from 'despia-native';

const previousBleDevice = globalThis.onBleDevice;
const handleBleDevice = event => {
  try {
    if (typeof previousBleDevice === 'function') previousBleDevice(event);
  } finally {
    event.devices.forEach(device => console.log(device.id, device.name, device.rssi));
  }
};
globalThis.onBleDevice = handleBleDevice;
const cleanupBleDevice = () => {
  if (globalThis.onBleDevice !== handleBleDevice) return;
  if (previousBleDevice === undefined) delete globalThis.onBleDevice;
  else globalThis.onBleDevice = previousBleDevice;
};
// Call cleanupBleDevice() when this component unmounts.

const previousBleValue = globalThis.onBleValue;
const handleBleValue = event => {
  try {
    if (typeof previousBleValue === 'function') previousBleValue(event);
  } finally {
    event.records.forEach(record => console.log(record.char, record.hex));
  }
};
globalThis.onBleValue = handleBleValue;
const cleanupBleValue = () => {
  if (globalThis.onBleValue !== handleBleValue) return;
  if (previousBleValue === undefined) delete globalThis.onBleValue;
  else globalThis.onBleValue = previousBleValue;
};
// Call cleanupBleValue() when this component unmounts.


const radioReply = await despia(`extension://ble/state?prompt=${encodeURIComponent(true)}`, ['bleState']);
const radio = radioReply.bleState;
if (radio === undefined) throw new Error('No native reply within 30 seconds');
if (!radio.ok) throw new Error(radio.code + ': ' + radio.error);

if (radio.data.state !== 'on') throw new Error(radio.data.state);
const scanReply = await despia(`extension://ble/scan_start?services=${encodeURIComponent('180d')}&seconds=${encodeURIComponent(10)}`, ['bleScanStart']);
const scan = scanReply.bleScanStart;
if (scan === undefined) throw new Error('No native reply within 30 seconds');
if (!scan.ok) throw new Error(scan.code + ': ' + scan.error);

// scan_start acknowledges the start. Wait for the native scan to finish.
const scanDeadline = Date.now() + 15000;
let scanning = true;
while (scanning && Date.now() < scanDeadline) {
  await new Promise(resolve => setTimeout(resolve, 500));
  const progressReply = await despia('extension://ble/state', ['bleState']);
  const progress = progressReply.bleState;
  if (progress === undefined) throw new Error('No native reply within 30 seconds');
  if (!progress.ok) throw new Error(progress.code + ': ' + progress.error);
  scanning = progress.data.scanning;
}
if (scanning) throw new Error('The native scan has not finished yet');

const foundReply = await despia('extension://ble/devices', ['bleDevices']);
const found = foundReply.bleDevices;
if (found === undefined) throw new Error('No native reply within 30 seconds');
if (!found.ok) throw new Error(found.code + ': ' + found.error);

console.log(found.data);
const stoppedReply = await despia('extension://ble/scan_stop', ['bleScanStop']);
const stopped = stoppedReply.bleScanStop;
if (stopped === undefined) throw new Error('No native reply within 30 seconds');
if (!stopped.ok) throw new Error(stopped.code + ': ' + stopped.error);
```

### Peripheral

```javascript
import despia from 'despia-native';

const SERVICE = '0000fff0-0000-1000-8000-00805f9b34fb';
const STATUS = '0000fff1-0000-1000-8000-00805f9b34fb';
const COMMAND = '0000fff2-0000-1000-8000-00805f9b34fb';
const previousBleRequest = globalThis.onBleRequest;
const handleBleRequest = event => {
  try {
    if (typeof previousBleRequest === 'function') previousBleRequest(event);
  } finally {
    console.log(event.records)
  }
};
globalThis.onBleRequest = handleBleRequest;
const cleanupBleRequest = () => {
  if (globalThis.onBleRequest !== handleBleRequest) return;
  if (previousBleRequest === undefined) delete globalThis.onBleRequest;
  else globalThis.onBleRequest = previousBleRequest;
};
// Call cleanupBleRequest() when this component unmounts.


const radioReply = await despia(`extension://ble/state?prompt=${encodeURIComponent(true)}`, ['bleState']);
const radio = radioReply.bleState;
if (radio === undefined) throw new Error('No native reply within 30 seconds');
if (!radio.ok) throw new Error(radio.code + ': ' + radio.error);

const serviceReply = await despia(`extension://ble/service_add?uuid=${encodeURIComponent(SERVICE)}&chars=${encodeURIComponent(STATUS + "~rn~00," + COMMAND + "~w")}`, ['bleServiceAdd']);
const service = serviceReply.bleServiceAdd;
if (service === undefined) throw new Error('No native reply within 30 seconds');
if (!service.ok) throw new Error(service.code + ': ' + service.error);

// Wait for native service registration before advertising.
const servicesReply = await despia('extension://ble/services', ['bleServices']);
const services = servicesReply.bleServices;
if (services === undefined) throw new Error('No native reply within 30 seconds');
if (!services.ok) throw new Error(services.code + ': ' + services.error);

console.log(services.data);
const storedReply = await despia(`extension://ble/value_set?service=${encodeURIComponent(SERVICE)}&char=${encodeURIComponent(STATUS)}&hex=${encodeURIComponent('01')}`, ['bleValueSet']);
const stored = storedReply.bleValueSet;
if (stored === undefined) throw new Error('No native reply within 30 seconds');
if (!stored.ok) throw new Error(stored.code + ': ' + stored.error);

const advertisingReply = await despia(`extension://ble/advertise_start?services=${encodeURIComponent(SERVICE)}&name=${encodeURIComponent('My Device')}&seconds=${encodeURIComponent(300)}`, ['bleAdvertiseStart']);
const advertising = advertisingReply.bleAdvertiseStart;
if (advertising === undefined) throw new Error('No native reply within 30 seconds');
if (!advertising.ok) throw new Error(advertising.code + ': ' + advertising.error);

console.log(advertising.data.applied);
```

### Missed events and the previous launch

Every event is also kept in a journal of up to 2000 records, each with a `seq`. The journal is written to the app's data directory within 250 ms of each event. A page that was not loaded when something happened reads it back:

```javascript
import despia from 'despia-native';

let after = 0;
const journalReply = await despia(`extension://ble/events?after=${encodeURIComponent(after)}&max=${encodeURIComponent(200)}`, ['bleEvents']);
const journal = journalReply.bleEvents;
if (journal === undefined) throw new Error('No native reply within 30 seconds');
if (!journal.ok) throw new Error(journal.code + ': ' + journal.error);

for (const record of journal.data.records) console.log(record);
after = journal.data.next;
```

Each launch is a run. `state` answers `run` (this launch) and `previousRun` (the launch before, or `null`). Pass `run` with the previous run's name to `events` to read what that launch recorded, for example notifications that arrived just before the system ended the app.

Ask for Bluetooth first: call `state` with `prompt=true` before the first scan, connect or server route, so the system prompt is answered before anything waits on it. A route that waited too long answers `timeout` and started nothing. Call it again. A `connect` to a device that is already connecting (for example one iOS brought back after your app relaunched) joins that attempt and resolves with its result.

### Posting to your server

Pass `server` (an HTTPS URL on a host the manifest allows) to `connect` and every link change of that device is posted as JSON:

```json
{"event": "ble_state", "deviceId": "...", "state": "connected", "timestamp": 1764000000.5, "background": true, "battery": 81}
```

A failed link adds `error` (the platform's message); a link that ended adds `reason`. Pass `server` to `subscribe` and every notified value of that characteristic is posted:

```json
{"event": "ble_data", "deviceId": "...", "service": "...", "characteristic": "...", "value": "AQI=", "valueHex": "0102", "timestamp": 1764000000.5, "background": false, "battery": 81}
```

`battery` is 0 to 100, or -1 when the system does not report it. Posts are sent one at a time, with a 15 second timeout and no redirects. A post that fails is retried after 30 seconds. Up to 500 posts wait in a queue in the app's data directory; when it is full, the oldest is dropped and counted. `state` answers `server` with `servers`, `pending` and `dropped`. A `disconnect` posts the last state and then stops watching that device. `unsubscribe` stops the posts for that characteristic.

### Routes

**Central**

| Route         | Parameters                                                                              | Answer `data`                                    | Answer variable | Callback |
| ------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------ | --- | --- |
| `state`       | `prompt`                                                                                | `state`, `authorization`, `scanning`, `advertising`, `links`, `centrals`, `keepAlive`, `epoch`, `run`, `previousRun`, `server` | `bleState` | `onBleState` |
| `events`      | `after` (0 or more), `max` (1 to 200), `run`                                            | `records`, `next`, `dropped`, `run`              | `bleEvents` | `onBleEvents` |
| `scan_start`  | `services` (comma-separated, up to 20), `names` (comma-separated, up to 10), `manufacturer_id` (0 to 65535) with optional `manufacturer_hex` (a data prefix), `seconds` (0 to 3600, 0 until `scan_stop`), `duplicates`, `mode`, and the scan options below | `scan`, `applied` | `bleScanStart` | `onBleScanStart` |
| `scan_stop`   | none                                                                                    | `scan`, `stopped`                                | `bleScanStop` | `onBleScanStop` |
| `devices`     | none                                                                                    | `devices` (up to 200)                            | `bleDevices` | `onBleDevices` |
| `connect`     | `id` (required), `auto`, `seconds` (0 to 20, default 10; 0 answers at once and waits with no limit), `server`, and the iOS connect options below | `id`, `link`, `state`, `mtu` | `bleConnect` | `onBleConnect` |
| `disconnect`  | `id` (required)                                                                         | `id`, `state`, `confirmed`                       | `bleDisconnect` | `onBleDisconnect` |
| `links`       | none                                                                                    | `links`                                          | `bleLinks` | `onBleLinks` |
| `discover`    | `id` (required)                                                                         | `id`, `services`                                 | `bleDiscover` | `onBleDiscover` |
| `read`        | `id`, `service`, `char` (required), `service_n`, `char_n`, `descriptor`                  | `hex`                                            | `bleRead` | `onBleRead` |
| `write`       | as `read`, plus one of `hex`, `b64` or `text` (UTF-8), `response` (default `true`)       | `written`, `chunks`                              | `bleWrite` | `onBleWrite` |
| `raw`         | `id` (required), one of `hex`, `b64` or `text`, `response` (default `true`)             | `written`, `chunks`, `service`, `char`, `service_n`, `char_n`, `response` | `bleRaw` | `onBleRaw` |
| `subscribe`   | `id`, `service`, `char` (required), `service_n`, `char_n`, `server`                     | `subscribed`, `mode`                             | `bleSubscribe` | `onBleSubscribe` |
| `unsubscribe` | `id`, `service`, `char` (required), `service_n`, `char_n`                               | `subscribed`, `mode`                             | `bleUnsubscribe` | `onBleUnsubscribe` |
| `rssi`        | `id` (required)                                                                         | `rssi`                                           | `bleRssi` | `onBleRssi` |
| `mtu`         | `id` (required), `size` (23 to 517)                                                     | `mtu`, `writeMax`, `writeNoResponseMax`, `requested` | `bleMtu` | `onBleMtu` |
| `priority`    | `id` (required), `level`: `balanced` (default), `high`, `low_power`, `dck`               | `level`                                          | `blePriority` | `onBlePriority` |
| `phy`         | `id` (required); without `tx` and `rx` it reads the PHY; `tx`, `rx` (comma-separated `1m`, `2m`, `coded`), `coded` (`none`, `s2`, `s8`) | `tx`, `rx` | `blePhy` | `onBlePhy` |
| `bond`        | `id` (required)                                                                         | `id`, `state`                                    | `bleBond` | `onBleBond` |
| `bonds`       | none                                                                                    | `devices` (`id`, `name`, `type`, `bond`)          | `bleBonds` | `onBleBonds` |
| `system_devices` | `services` (required on iOS)                                                         | `devices`                                        | `bleSystemDevices` | `onBleSystemDevices` |
| `connection_events` | `services`, `ids` (comma-separated device ids)                                    | `services`, `ids`, `applied`                     | `bleConnectionEvents` | `onBleConnectionEvents` |

`bond` answers `bonding` (or the current state when the device is already bonded) and the `bond` event reports the result.

`raw` writes to the first discovered characteristic that takes the write type, as the retired core did, and names it in the answer. Call `discover` first.

Scan options of `scan_start`: `mode` also takes `opportunistic` (Android: results only from other apps' scans); `legacy` and `phy` (`1m`, `coded`, `all`) for extended advertising; `report_delay` (0 to 600000 ms, batched results); `callback_type` (`all`, `first_match`, `first_match_lost`; a lost device arrives in `device` with `lost: true`); `match` (`aggressive`, `sticky`); `matches` (`one`, `few`, `max`); `solicited` (service UUIDs the peripheral solicits). An option this platform has no API for is ignored and reported `false` in `applied`; an unknown option answers `bad_value`.

iOS connect options of `connect`: `notify_on_connection`, `notify_on_disconnection` and `notify_on_notification` (the system alerts while the app is suspended), `transport_bridging`, `requires_ancs`, and `system_reconnect` (iOS 17: the system reconnects the peripheral after the link drops). Android has no such options; they are ignored there.

**Peripheral**

| Route             | Parameters                                                                     | Answer `data`                       | Answer variable | Callback |
| ----------------- | ------------------------------------------------------------------------------ | ----------------------------------- | --- | --- |
| `service_add`     | `uuid` (required), `primary` (default `true`), `chars`                         | `uuid`, `characteristics`           | `bleServiceAdd` | `onBleServiceAdd` |
| `service_remove`  | `uuid`; without it, every service                                              | `removed`                           | `bleServiceRemove` | `onBleServiceRemove` |
| `services`        | none                                                                           | `services`, `advertising`           | `bleServices` | `onBleServices` |
| `value_set`       | `service`, `char` (required), `char_n`, one of `hex`, `b64` or `text` (up to 512 bytes) | `bytes`                    | `bleValueSet` | `onBleValueSet` |
| `notify`          | as `value_set`, plus `central` (one central; without it, every subscribed one) | `sent`, `subscribers`               | `bleNotify` | `onBleNotify` |
| `advertise_start` | `services`, `name` (up to 26), `manufacturer_id` with `manufacturer_hex`, `service_data_uuid` with `service_data_hex`, `connectable` (default `true`), `mode`, `seconds` (0 to 3600), `tx_power` (`ultra_low`, `low`, `medium`, `high`), `include_tx_power` | `advertising`, `applied` | `bleAdvertiseStart` | `onBleAdvertiseStart` |
| `advertise_stop`  | none                                                                           | `advertising`                       | `bleAdvertiseStop` | `onBleAdvertiseStop` |
| `centrals`        | none                                                                           | `centrals`                          | `bleCentrals` | `onBleCentrals` |
| `central_drop`    | `central` (required)                                                           | `dropped`                           | `bleCentralDrop` | `onBleCentralDrop` |
| `keep_alive`      | `enabled` (required)                                                           | `enabled`, `active`, `reason`       | `bleKeepAlive` | `onBleKeepAlive` |
| `respond`         | `request` (required), `status` (default `ok`), for a read answered `ok` one of `hex`, `b64` or `text` (up to 512 bytes), `offset` (Android) | `request`, `status`, `bytes` | `bleRespond` | `onBleRespond` |
| `advertise_set_start` | the advertising set parameters below (Android)                             | `set`, `tx_power`                   | `bleAdvertiseSetStart` | `onBleAdvertiseSetStart` |
| `advertise_set_stop`  | `set` (required)                                                           | `set`, `state`                      | `bleAdvertiseSetStop` | `onBleAdvertiseSetStop` |

**L2CAP channels**

| Route             | Parameters                                                                     | Answer `data`                       | Answer variable | Callback |
| ----------------- | ------------------------------------------------------------------------------ | ----------------------------------- | --- | --- |
| `l2cap_publish`   | `encrypted` (default `true`)                                                   | `psm`, `encrypted`                  | `bleL2capPublish` | `onBleL2capPublish` |
| `l2cap_unpublish` | `psm` (required)                                                               | `psm`, `published`                  | `bleL2capUnpublish` | `onBleL2capUnpublish` |
| `l2cap_open`      | `id` and `psm` (1 to 255) (required), `encrypted` (default `true`, Android), `seconds` (1 to 20, default 10) | `channel`, `psm`, `id` | `bleL2capOpen` | `onBleL2capOpen` |
| `l2cap_send`      | `channel` (required), one of `hex`, `b64` or `text` (up to 2048 bytes)        | `channel`, `bytes`                  | `bleL2capSend` | `onBleL2capSend` |
| `l2cap_close`     | `channel` (required)                                                           | `channel`, `state`                  | `bleL2capClose` | `onBleL2capClose` |
| `l2cap_channels`  | none                                                                           | `channels`, `published`             | `bleL2capChannels` | `onBleL2capChannels` |

`chars` of `service_add` lists up to 16 characteristics, comma-separated, each `uuid~flags` or `uuid~flags~hex` (the starting value). Flags: `r` read, `w` write, `c` write without response, `n` notify, `i` indicate, `R` read needs encryption (with `r`), `W` write needs encryption (with `w` or `c`), and `a`: the page answers this characteristic's reads and writes itself (with `r`, `w` or `c`).

**Requests the page answers.** A read or write of a characteristic with flag `a` arrives in `att_request` with `state: "open"`, a `request` number, `kind` (`read` or `write`), the `central`, and for a read the `service`, `char`, `char_n` and `offset`, for a write the `writes` (each `service`, `char`, `char_n`, `offset`, `hex`). Answer it with `respond`: `status` is `ok`, `not_permitted`, `invalid_offset`, `invalid_length`, `insufficient_authentication`, `insufficient_authorization`, `insufficient_encryption`, `not_supported`, `insufficient_resources` or `unlikely`, and a read answered `ok` carries the value from the request's offset. A request not answered within 25 seconds is answered `unlikely` for you and reported `state: "expired"` (a central gives up after ATT's 30-second transaction timeout). A request whose central left, or whose adapter went off, is reported `state: "dropped"`. A write the central sent without asking for an answer (Android) is reported `state: "unanswered"` with `request: null`. Writes to characteristics without `a` in the same batch are stored when the page answers `ok`; the page's own characteristic keeps no value, so set it with `value_set` if you also want it served.

**L2CAP channels** carry a byte stream without GATT. The peripheral role publishes a channel with `l2cap_publish` and tells the central its `psm` (for example in a characteristic); each central that opens it appears in the `l2cap` event with `role: "peripheral"`. The central role opens one with `l2cap_open`. Bytes arrive in `l2cap_data` (`records` of `channel` and `hex`, batched like `value`), and `l2cap_send` hands bytes to the channel. The `l2cap` event reports each channel `open` and `closed` (`reason`: `remote`, `error` with `error`, `requested` or `adapter`).

**Advertising sets (Android).** `advertise_set_start` starts one more advertisement beside `advertise_start`, with Android's AdvertisingSetParameters: `legacy` (default `false`: extended advertising), `connectable`, `scannable`, `anonymous`, `include_tx_power` (in the header), `primary_phy` (`1m`, `coded`), `secondary_phy` (`1m`, `2m`, `coded`), `interval_ms` (100 to 10485759), `tx_power_dbm` (-127 to 1). The data: `services`, `include_name`, `manufacturer_id` with `manufacturer_hex`, `service_data_uuid` with `service_data_hex`, `tx_power_data`. A scannable set takes a scan response: `response_services`, `response_include_name`, `response_manufacturer_id` with `response_manufacturer_hex`. Periodic advertising (an extended set that is neither connectable nor scannable): `periodic_interval_ms` (100 to 81898), `periodic_include_tx_power`, `periodic_manufacturer_id` with `periodic_manufacturer_hex`, `periodic_service_data_uuid` with `periodic_service_data_hex`. `seconds` (0 to 655, 0 until stopped) and `max_events` (0 to 255) end the set; the `advertising_set` event reports it `started` (with `tx_power`, the power the controller chose, in dBm) and `stopped` (`reason`: `elapsed`, `requested` or `adapter`). A combination Android refuses (a legacy set that is anonymous, connectable and not scannable, or not on the 1M PHY; an extended set that is both connectable and scannable, or connectable and anonymous) answers `bad_value` with the rule.

`mode` is `low_power`, `balanced` or `low_latency`. A device `id` is the iOS peripheral identifier or the Android MAC address. UUIDs can be 16, 32 or 128 bit in any case; answers always use lower-case 128-bit. `service_n` and `char_n` number equal UUIDs in discovery order. Notifications and indications are both handled by `subscribe`; the answer's `mode` says which the characteristic uses.

### Events

| Event              | Callback               | Scope      | When                                                         |
| ------------------ | ---------------------- | ---------- | ------------------------------------------------------------ |
| `adapter`          | `onBleAdapter`         | `app`      | Bluetooth turned on or off                                   |
| `restored`         | `onBleRestored`        | `app`      | iOS restored the Bluetooth state after a relaunch            |
| `device`           | `onBleDevice`          | `document` | Devices found by a scan, batched every 50 ms                 |
| `scan_end`         | `onBleScanEnd`         | `document` | A scan ended                                                 |
| `link`             | `onBleLink`            | `document` | A link connected, is reconnecting, or disconnected           |
| `value`            | `onBleValue`           | `document` | Notified or indicated values, batched every 50 ms            |
| `gatt_changed`     | `onBleGattChanged`     | `document` | A device changed its services                                |
| `central`          | `onBleCentral`         | `document` | A central connected, disconnected, subscribed or unsubscribed |
| `request`          | `onBleRequest`         | `document` | Writes from centrals, batched                                |
| `advertise_end`    | `onBleAdvertiseEnd`    | `document` | Advertising stopped, elapsed, lost the adapter, or failed    |
| `bond`             | `onBleBond`            | `document` | A bond changed (`id`, `state`, `previous`), on Android       |
| `phy`              | `onBlePhy`             | `document` | The link's PHY changed (`id`, `link`, `tx`, `rx`), on Android |
| `connection_event` | `onBleConnectionEvent` | `document` | A watched device connected to or disconnected from the system, for any app (`id`, `event`, `name`) |
| `ancs`             | `onBleAncs`            | `document` | A peripheral's notification-center authorization changed (`id`, `authorized`), on iOS |
| `att_request`      | `onBleAttRequest`      | `document` | A read or write of a characteristic with flag `a` waits for `respond`, or was answered, expired or dropped |
| `l2cap`            | `onBleL2cap`           | `document` | An L2CAP channel opened or closed (`channel`, `state`, `role`, `peer`, `psm`, `reason`) |
| `l2cap_data`       | `onBleL2capData`       | `document` | Bytes received on L2CAP channels, batched every 50 ms         |
| `advertising_set`  | `onBleAdvertisingSet`  | `document` | An advertising set started or stopped, on Android             |

`restored` carries `peripherals` and `scanning` for the central role, and `services`, `advertising` and `lost` for the server role. Every event is also a journal record, so a page that was not loaded when it happened reads it with `events`.

### Error codes

A failed `connect` answers `connect_failed`. Its message and the `link` event carry the platform's own error: `error: {domain, code, message, name}`, the CoreBluetooth error on iOS and the GATT status on Android. A known code also gives a readable `reason`, such as `encryption_timeout`.

Besides the standard codes: `busy`, `unavailable`, `permission_denied`, `scan_failed`, `bad_value`, `unknown_device`, `not_connected`, `not_found`, `not_permitted`, `too_long`, `connect_failed`, `connect_timeout`, `gatt_error`, `link_lost`, `filter_required` (a scan in the background needs a service filter), `advertise_failed`, `no_subscribers`, `l2cap_failed` (the platform did not publish or open the channel; the message carries its error) and `platform_limit` (this platform has no such API; the message names it).

---

## From the retired `bluetooth://` core

The Despia V3 runtime had a built-in `bluetooth://` scheme on iOS only. It has been removed from the runtime; this extension covers all of it on iOS and Android.

| `bluetooth://` | This extension |
| --- | --- |
| `state` | `state` (`authorization` and the `adapter` event) |
| `window.bluetoothActive` | `state` answers `authorization` |
| `scan?services&duration` | `scan_start?services&seconds` |
| `stopscan` | `scan_stop` |
| `connect?id&timeout&auto_connect&server` | `connect?id&seconds&auto&server` (`seconds=0`: no time limit, as before) |
| `disconnect` | `disconnect` |
| `discover` | `discover` |
| `read` | `read` |
| `write` with `text`, `hex` or `value` | `write` with `text`, `hex` or `b64` |
| `raw` | `raw` |
| `subscribe?server`, `unsubscribe` | `subscribe?server`, `unsubscribe` |
| `rssi` | `rssi` |
| Server posts `ble_state` and `ble_data` | The same bodies, with a retry queue that survives a restart |
| Replay queue of 500 events across termination | The journal (2000 records), and `events?run=` for the previous launch |
| Events `device`, `scanEnd`, `connect`, `discovered`, `data`, `writeComplete`, `rssi`, `state`, `raw` | `device`, `scan_end`, `link`, `value`, `adapter`, and each route's answer |

---

## Platform limits

Each limit below is a capability the platform has no public API for. The route answers `platform_limit` and names it, or the answer's `applied` reports the option `false`. Sources were read on 2026-11-24.

- **iOS, connection priority and PHY.** CoreBluetooth has no API to request a connection interval or read or set the LE PHY; the system and the peripheral choose them. `priority` and `phy` on a connected device answer `platform_limit` (on a device that is not connected, `not_connected`). Source: [CBPeripheral](https://developer.apple.com/documentation/corebluetooth/cbperipheral).
- **iOS, bonding.** No API to start, list or remove a bond. The system pairs when a peripheral requires encryption for an attribute the app reads or writes. `bond` and `bonds` answer `platform_limit`. Source: [CBPeripheral](https://developer.apple.com/documentation/corebluetooth/cbperipheral) and [CBCentralManager](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager), which have no bonding API.
- **iOS, scanning and advertising.** No scan `mode`, `report_delay`, `callback_type`, `match`, `matches`, `legacy` or `phy`, no name or manufacturer filter in the scan itself (the extension filters the results), and no MTU request (`mtu` answers `requested: false`). No API to drop a central (`central_drop` answers `platform_limit`). An advertisement carries only service UUIDs and a local name, is always connectable, has no TX power setting, and in the background carries no name. In the background, a scan without a service filter is stopped, and a new one answers `filter_required`. `system_devices` needs `services`. Sources: [CBCentralManager](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager), [CBPeripheralManager.startAdvertising](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)).
- **iOS, advertising sets.** CBPeripheralManager has one advertisement with service UUIDs and a local name; it has no extended or periodic advertising and no advertising-set API. `advertise_set_start` answers `platform_limit`; use `advertise_start`. Source: [CBPeripheralManager.startAdvertising](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)).
- **iOS, L2CAP and page-answered writes.** `openL2CAPChannel` opens a channel only on a peripheral this app is connected to, so `l2cap_open` needs `connect` first (otherwise `not_connected`), and it has no encryption option: the peripheral's published channel decides. iOS delivers writes with and without response to the same callback, so on iOS every write to a characteristic with flag `a` waits for `respond`. Sources: [CBPeripheral.openL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbperipheral/openl2capchannel(_:)), [CBPeripheralManager.respond](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/respond(to:withresult:)).
- **iOS, reads.** A characteristic value and a read answer arrive through the same callback, so a notification that lands while a read of the same characteristic is in flight answers that read.
- **Android, versions.** `legacy` and `phy` in a scan and the `phy` route need Android 8.0 (API 26). `priority` with `dck` needs Android 14 (API 34). Earlier versions answer `platform_limit`. `requestConnectionPriority` has no completion callback, so `priority` answers once the system accepts the request. Source: [BluetoothGatt](https://developer.android.com/reference/android/bluetooth/BluetoothGatt).
- **Android, L2CAP and advertising sets.** LE L2CAP channels need Android 10 (API 29: `listenUsingL2capChannel`, `createL2capChannel`); advertising sets need Android 8.0 (API 26: `startAdvertisingSet`). Earlier versions answer `platform_limit`. A set this phone's controller cannot send answers `platform_limit` naming the adapter's own answer: extended advertising (`isLeExtendedAdvertisingSupported`), the Coded PHY (`isLeCodedPhySupported`), the 2M PHY (`isLe2MPhySupported`) or periodic advertising (`isLePeriodicAdvertisingSupported`); a legacy set works on every controller that advertises. Sources: [BluetoothDevice.createL2capChannel](https://developer.android.com/reference/android/bluetooth/BluetoothDevice#createL2capChannel(int)), [BluetoothLeAdvertiser.startAdvertisingSet](https://developer.android.com/reference/android/bluetooth/le/BluetoothLeAdvertiser), [BluetoothAdapter](https://developer.android.com/reference/android/bluetooth/BluetoothAdapter).
- **Android, connection events.** `connection_event` comes from the system's ACL broadcasts, which carry the device but no service list: `ids` filter, `services` cannot (`applied.services` is `false`). Classic Bluetooth links appear too. Source: [BluetoothDevice.ACTION_ACL_CONNECTED](https://developer.android.com/reference/android/bluetooth/BluetoothDevice#ACTION_ACL_CONNECTED).
- **Android, bonds.** No public API removes a bond; the user removes it in the system Bluetooth settings. Source: [BluetoothDevice](https://developer.android.com/reference/android/bluetooth/BluetoothDevice) (public `createBond` only).
- **Android, other.** No state restoration: links, the server and advertising end with the app's process. Use `keep_alive` to keep links while the app is in the background. With `name`, Android advertises the device's own Bluetooth name. A controller without advertising support answers `platform_limit`. The iOS connect options do not exist.
- **Both.** One GATT operation runs at a time per link, up to 64 wait, and each has a 10 second timeout that closes the link. Writes are at most 512 bytes. A write without response means the bytes were handed to the system, not that they were delivered.

## License

[Despia V3 Extension Source-Available Commercial License](LICENSE), version 1.4.
This template is proprietary and source available.

You may inspect, fork, customize, build and run it for noncommercial development,
evaluation and testing without a paid Despia license, including work on an app
you plan to release commercially later.

Production or commercial use requires a valid Despia project and an applicable
Despia license for that application and operating system. A Solo Pack covers
its licensed OS, iOS or Android. A Hybrid Pack covers both. Your applicable
license includes all provided V3 templates you have lawful access to and any
number of your own extensions, with no separate extension purchase or
per-extension fee.

Keep the license and applicable notices. Third-party material keeps its own
terms. Experimental V3 extensions do not include a commitment to maintenance
or a V4 port. See [LICENSE](LICENSE) for the full terms and [Despia](https://despia.com)
for licensing.
