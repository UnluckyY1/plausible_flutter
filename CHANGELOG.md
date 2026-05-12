## 0.4.0

Initial public release.

* `Plausible.init` / `trackEvent` / `trackPageView` for sending events to
  Plausible Analytics' `/api/event` endpoint over HTTP — no JavaScript, no
  WebView.
* Offline-first event queue backed by Hive. Events that fail to send are
  persisted to disk and retried automatically on connectivity change, on
  app resume, on a periodic timer (default 5 min), and on the next `init()`.
* Auto-detected User-Agent and default props (`app_version`, `platform`,
  `os_version`, `device_model`) via `package_info_plus` + `device_info_plus`,
  so Plausible's *OS / Browser / Device* breakdowns populate out of the box.
* Optional `PlausibleNavigatorObserver` for auto pageview tracking, with a
  custom-filter factory for multi-Navigator apps.
* Native HTTP via `native_dio_adapter` (URLSession on iOS / macOS, Cronet on
  Android), browser XHR on web, default `HttpClient` on Windows / Linux. Web
  conditional imports key on `dart.library.js_interop` so both JS and WASM
  builds work.
* Public outcome enum `PlausibleSendResult { success, queued, dropped,
  disabled }` returned from every `track*` call.
* Runtime kill-switch via `setEnabled(bool)`.
* GDPR-friendly `disableAutoDeviceProps` flag to strip `device_model` from
  the default props and the Android UA.
* Optional `package:logger` injection to route the package's logs into your
  app's logging stack.
* Six-platform support: **iOS, Android, macOS, Windows, Linux, Web**.
