# plausible_flutter

[![pub package](https://img.shields.io/pub/v/plausible_flutter.svg)](https://pub.dev/packages/plausible_flutter)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Flutter package for sending pageviews and custom events to
[Plausible Analytics](https://plausible.io). No JavaScript, no WebView, no
data loss when the user goes offline. Works on **iOS, Android, macOS,
Windows, Linux, and Web**.

```dart
await Plausible.init(
  domain: 'yourapp.com',
  apiHost: 'https://plausible.io',
);

await Plausible.instance.trackEvent('button_clicked', props: {'screen': 'home'});
```

That's the whole API surface for the happy path. Everything else is opt-in.

## Why this exists

There are a handful of Plausible Flutter packages already, but most of them
are thin HTTP wrappers — fine for a quick prototype, but they lose events
the moment your user steps onto a subway. This one was built to be
production-ready out of the box:

- **Offline-first.** Events that fail to send are persisted to disk (Hive)
  and retried automatically when the network comes back, the app foregrounds,
  or every five minutes — whichever happens first.
- **Plausible-friendly metadata.** Auto-builds a browser-style User-Agent so
  Plausible's *OS / Browser / Device* breakdowns actually populate, and
  attaches `app_version`, `platform`, `os_version`, `device_model` as
  custom props so you can filter by them in the dashboard.
- **Native HTTP where it matters.** Uses `native_dio_adapter` to route
  through URLSession (iOS / macOS) and Cronet (Android) by default, and
  cleanly falls back to the browser's `XHR` on web — without dragging
  `dart:ffi` into your web bundle.
- **Honest failure modes.** Every `track*` call returns a
  `PlausibleSendResult` (`success` / `queued` / `dropped` / `disabled`) so
  you actually know what happened.

## Installation

```yaml
dependencies:
  plausible_flutter: ^0.4.0
```

### Android: Cronet

The native HTTP adapter on Android needs Cronet. Add to
`android/app/build.gradle`:

```gradle
dependencies {
    implementation 'org.chromium.net:cronet-embedded:119.6045.31'
}
```

(Or use Cronet Play Services — see the
[`cronet_http`](https://pub.dev/packages/cronet_http) docs.)

### macOS: network entitlement

A fresh Flutter macOS app sandboxes outbound network. Add the client
entitlement to both
`macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

iOS, Web, Windows, and Linux need no extra setup.

## Quick start

### 1. Initialize once at startup

```dart
import 'package:flutter/foundation.dart';
import 'package:plausible_flutter/plausible_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Plausible.init(
    domain: 'yourapp.com',           // site id in your Plausible dashboard
    apiHost: 'https://plausible.io', // or your self-hosted URL
    enableAutoPageviews: true,       // wire the navigator observer below
    enabled: !kDebugMode,            // don't track yourself during dev
  );

  runApp(const MyApp());
}
```

`userAgent` and `defaultProps` are auto-detected — pass them explicitly only
if you want to override.

| Auto-detected field | Source                | Example                                                              |
| ------------------- | --------------------- | -------------------------------------------------------------------- |
| `userAgent`         | package + device info | `Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) YourApp/1.0` |
| `app_version`       | `package_info_plus`   | `1.0.0`                                                              |
| `platform`          | `dart:io` / `kIsWeb`  | `ios`, `android`, `macos`, `windows`, `linux`, `web`                 |
| `os_version`        | `device_info_plus`    | `17.4` / `14`                                                        |
| `device_model`      | `device_info_plus`    | `iPhone15,3` / `SM-G991B`                                            |

The User-Agent powers Plausible's *OS / Browser / Device* breakdowns; the
custom props show up under *Custom properties* for filtering ("which app
version has the most signups?").

### 2. Track events

```dart
// Custom event with props:
await Plausible.instance.trackEvent(
  'signup_completed',
  props: {'plan': 'pro', 'referral': 'twitter'},
);

// Manual pageview:
await Plausible.instance.trackPageView('/users/$userId/settings');
```

Per-call props merge on top of the auto-detected defaults — your keys win on
conflict.

### 3. Auto-track pageviews

```dart
MaterialApp(
  navigatorObservers: [Plausible.navigatorObserver],
  // ...
);
```

Pageviews fire on **push and replace only** — pops don't double-count the
route you're returning to, and the previous route name is forwarded as
`referrer` so Plausible's *Top Sources* report works. Routes without a
`settings.name` (anonymous `MaterialPageRoute`s, dialogs, modal sheets) are
skipped by default — otherwise the dashboard fills up with `/` pageviews
from every `showDialog`.

Use named routes for meaningful labels:

```dart
Navigator.of(context).pushNamed('/settings');
```

Or give your anonymous route a name where you build it:

```dart
showDialog(
  context: context,
  routeSettings: const RouteSettings(name: 'dialog:confirm-delete'),
  builder: ...,
);
```

#### Custom routing rules

Need to skip specific routes, or rename them?

```dart
navigatorObservers: [
  Plausible.createNavigatorObserver(
    filter: (route) {
      final name = route.settings.name;
      if (name == null) return null;       // skip unnamed
      if (name == '/secret') return null;  // explicit skip
      return name;                         // pass through (or rename)
    },
  ),
],
```

> **One observer per `Navigator`.** `Plausible.navigatorObserver` is a
> singleton, and `NavigatorObserver` itself isn't safe to share across
> multiple Navigators (tabbed apps, nested routers) — Flutter overwrites the
> observer's `navigator` field on each attach. For multi-Navigator apps,
> build a fresh observer per `Navigator` with `createNavigatorObserver()`.

### 4. (Optional) Plug in your own `Logger`

The package logs through [`package:logger`](https://pub.dev/packages/logger).
Out of the box it uses an internal logger gated by the `debug:` flag. Pass
your own to route plausible's output into your app's logging stack:

```dart
import 'package:logger/logger.dart';

await Plausible.init(
  domain: 'yourapp.com',
  apiHost: 'https://plausible.io',
  logger: Logger(
    printer: PrettyPrinter(methodCount: 0, colors: true),
    level: Level.info, // hide per-event debug traces in prod
  ),
);
```

| Level   | What it carries                                                                   |
| ------- | --------------------------------------------------------------------------------- |
| `debug` | per-event traces: `sent pageview → 202`, `queued NAME (N pending)`, `drain paused` |
| `info`  | lifecycle: `initialized for DOMAIN`, `queue ready (N pending)`                    |
| `warn`  | recoverable: `retry later NAME: ...`, `drop NAME: 400 ...`, `queue unavailable`   |
| `error` | unexpected exceptions, with the original error attached                           |

## How offline retry works

Every `trackEvent` / `trackPageView` call resolves to one of four outcomes:

| What happened                                                          | What we do                                                          | Returns       |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------- |
| Live POST returned 2xx                                                 | Done.                                                               | `success`     |
| Live POST returned 4xx (≠ 408, 429)                                    | Payload is invalid — drop, don't retry.                             | `dropped`     |
| Live POST failed transiently and was persisted                         | Retry on connectivity change, app resume, `retryInterval`, or `init()`. | `queued`      |
| Queue was already non-empty — no POST attempted, event appended (FIFO) | Will ship on the next drain.                                        | `queued`      |
| Transient fail AND the queue is unavailable (Hive can't open)          | Event is genuinely lost.                                            | `dropped`     |
| `enabled: false`                                                       | No-op — never touched the network or the queue.                     | `disabled`    |

The queue is FIFO and capped at `maxQueueSize` (default 1000). When the cap
is hit, the **oldest events are silently evicted** so the on-disk box can't
grow unbounded — if your users routinely go offline for long stretches and
you care about retention, raise the cap.

If Hive itself fails to open (corrupt database, full disk, IndexedDB
disabled in private-mode Safari, …), `init()` **does not throw**. The
package degrades to fire-and-forget mode and logs a warning. An analytics
package should never be the reason your app crashes.

## Privacy

By default each event carries `app_version`, `platform`, `os_version`,
`device_model` (mobile only), and a browser-style User-Agent built from
those. For privacy-conscious deployments, `device_model` is usually the
concern — pass `disableAutoDeviceProps: true` to drop it entirely (and to
skip the device segment in the Android UA).

The package never sends the user's IP unless you explicitly pass
`xForwardedFor`; Plausible records whatever the connecting IP is. The Events
API endpoint itself is unauthenticated (same as the JS tracker) — there's
no API key to leak.

**Consent is on you.** This package will happily collect and send analytics
the moment `init()` returns. If you operate under GDPR / CCPA or similar,
gate `init()` (or use `setEnabled(false)` then flip on after consent) until
the user agrees.

**Don't put PII in event names, paths, or props.** Anything you pass to
`trackEvent` / `trackPageView` ends up both on the Plausible server and in
the local Hive queue. Email addresses, names, tokens, and user-typed search
strings should never be event identifiers.

**Use `https://` for `apiHost` in production.** The SDK accepts `http://`
(useful for local dev), but it will log a warning — analytics traffic and
your `X-Forwarded-For` header travel in cleartext on plain HTTP.

**Encrypting the on-disk queue.** The offline queue persists pending events
to a local Hive box in plaintext by default. Pass a 32-byte
`encryptionKey` to `Plausible.init` to enable AES-256 at-rest encryption:

```dart
await Plausible.init(
  domain: 'yourapp.com',
  apiHost: 'https://plausible.io',
  encryptionKey: yourKey, // 32 bytes, e.g. from flutter_secure_storage
);
```

Key management is the integrator's responsibility — typically store a
generated key in `flutter_secure_storage` (iOS Keychain / Android
Keystore-backed) and read it before calling `init`.

## Configuration reference

| Parameter                | Default        | Notes                                                              |
| ------------------------ | -------------- | ------------------------------------------------------------------ |
| `domain` *(required)*    | —              | Site id in your Plausible dashboard.                               |
| `apiHost` *(required)*   | —              | `https://plausible.io` for Cloud, or your self-hosted URL.         |
| `userAgent`              | auto-detected  | Override the auto-built browser-style UA. `null` on web (browsers reject it). |
| `defaultProps`           | auto-detected  | Merged with auto-detected props (per-event keys win).              |
| `xForwardedFor`          | `null`         | Override the visitor IP Plausible records.                         |
| `enabled`                | `true`         | Master kill-switch. Also flippable at runtime via `setEnabled`.    |
| `enableAutoPageviews`    | `false`        | Toggles the default `Plausible.navigatorObserver`.                 |
| `disableAutoDeviceProps` | `false`        | Drop `device_model` from default props + the Android UA.           |
| `debug`                  | `false`        | Enables the internal logger at `Level.debug`.                      |
| `timeout`                | `10s`          | Per-request send/receive timeout. (Caveat: when you inject your own Dio, `connectTimeout` lives only on `BaseOptions` — set it there.) |
| `maxQueueSize`           | `1000`         | FIFO eviction beyond this.                                         |
| `retryInterval`          | `5m`           | Periodic drain attempt. `Duration.zero` disables the timer.        |
| `encryptionKey`          | `null`         | 32-byte AES-256 key for the on-disk queue. `null` = plaintext.     |
| `dio`                    | native adapter | Inject your own `Dio` (mock adapter for tests, custom interceptors, etc.). |
| `logger`                 | internal       | Inject a `package:logger` `Logger` to route logs into your stack.  |

## Platform support

| Layer                       | iOS | Android | macOS | Windows | Linux | Web                                   |
| --------------------------- | --- | ------- | ----- | ------- | ----- | ------------------------------------- |
| Plausible Events API (Dio)  | ✅  | ✅      | ✅    | ✅      | ✅    | ✅ (`BrowserClient`)                  |
| `native_dio_adapter`        | ✅  | ✅      | ✅    | ✅\*    | ✅\*  | n/a (excluded via conditional import) |
| Hive offline queue          | ✅  | ✅      | ✅    | ✅      | ✅    | ✅ (IndexedDB)                        |
| `connectivity_plus`         | ✅  | ✅      | ✅    | ✅      | ✅    | ✅ (`navigator.onLine`)               |

\* On Windows/Linux, `native_dio_adapter` itself falls back to the default
Dart `HttpClient`. On Web we **exclude it entirely** — its transitive deps
(`cronet_http`, `cupertino_http`) import `dart:ffi`, which neither dart2js
nor dart2wasm can compile. The conditional import keys on
`dart.library.js_interop`, so the same code works on both JS and WASM
web targets.

## Testing your own code

Pass a custom `Dio` to inject any adapter you like:

```dart
final mockDio = Dio()..httpClientAdapter = MyMockAdapter();
await Plausible.init(
  domain: 'yourapp.com',
  apiHost: 'https://plausible.io',
  dio: mockDio,
);
```

The package itself ships with ~50 tests covering the queue, mutex,
cancellation, FIFO under concurrent calls, lifecycle drains, and platform
metadata — run them with:

```bash
flutter test
```

## Contributing

Issues and PRs welcome. The codebase is small and reasonably documented;
start with `lib/src/plausible.dart` and follow the calls.

## License

[MIT](LICENSE) — Copyright © 2026 Yassine Ben Massaoud and Oodrive.
