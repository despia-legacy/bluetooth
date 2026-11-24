# Route test

`plan-ios.json` and `plan-android.json` call every route in `manifest.json` once, with a device id that is not connected. A test page in the built app makes each call through `despia-native` and posts each answer. `check_routes.py` checks the answers against the documented contract:
- each route answers once;
- the answer has the standard envelope;
- an error carries a documented code and message;
- `state` answers;
- on iOS, the bond routes and `advertise_set_start` answer `platform_limit`.

```sh
python3 -I tests/route/check_routes.py ios tests/route/plan-ios.json results.jsonl
```

Neither simulator nor emulator has a Bluetooth peer, so this proves the answers for state, permission, a missing radio and a device that is not connected, not a real radio.
