import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:logger/logger.dart';

import 'platform_info.dart';
import 'plausible_client.dart';
import 'plausible_config.dart';
import 'plausible_event.dart';
import 'plausible_logger.dart';
import 'plausible_navigator_observer.dart';
import 'plausible_queue.dart';

/// The package's entry point.
///
/// Call [Plausible.init] once during app startup (before `runApp`), then
/// fire events via [Plausible.instance]:
///
/// ```dart
/// await Plausible.init(
///   domain: 'yourapp.com',
///   apiHost: 'https://plausible.io',
/// );
/// await Plausible.instance.trackEvent('signup');
/// ```
///
/// All `track*` calls return a [PlausibleSendResult] so you can tell whether
/// the event was sent live, queued for retry, dropped, or skipped.
class Plausible {
  static Plausible? _instance;

  /// The singleton you use for tracking. Throws [StateError] if
  /// [Plausible.init] hasn't been awaited yet — use [isInitialized] to check
  /// without throwing.
  static Plausible get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
        'Plausible.init() must be called before accessing Plausible.instance',
      );
    }
    return i;
  }

  /// `true` once [Plausible.init] has completed. Useful for guarding calls in
  /// code paths that may run before startup finishes.
  static bool get isInitialized => _instance != null;

  /// Default observer for auto-pageview tracking. Wire it into a single
  /// `MaterialApp.navigatorObservers` and pass `enableAutoPageviews: true`
  /// to [Plausible.init] to turn it on:
  ///
  /// ```dart
  /// MaterialApp(
  ///   navigatorObservers: [Plausible.navigatorObserver],
  ///   // ...
  /// )
  /// ```
  ///
  /// **One Navigator at a time.** `NavigatorObserver` stores the `Navigator`
  /// it's attached to in a field that Flutter overwrites on each attach.
  /// Sharing this singleton across multiple Navigators (tabbed apps, nested
  /// routers) silently breaks the earlier attachment. In those cases use
  /// [createNavigatorObserver] to get a fresh observer per Navigator.
  static final PlausibleNavigatorObserver navigatorObserver =
      PlausibleNavigatorObserver(respectGlobalFlag: true);

  /// Build a fresh observer with a custom [filter] — for renaming routes,
  /// skipping specific ones, or attaching to a non-root Navigator.
  ///
  /// ```dart
  /// Plausible.createNavigatorObserver(
  ///   filter: (route) {
  ///     final name = route.settings.name;
  ///     if (name == null || name.startsWith('/admin/')) return null;
  ///     return name;
  ///   },
  /// )
  /// ```
  ///
  /// The returned observer ignores the `enableAutoPageviews` flag — if you
  /// construct one explicitly, you've opted in.
  static PlausibleNavigatorObserver createNavigatorObserver({
    PlausibleRouteFilter? filter,
  }) => PlausibleNavigatorObserver(filter: filter);

  final PlausibleConfig config;
  final PlausibleQueue _queue;
  final PlausibleLogger _logger;
  bool _enabled;

  Plausible._internal({
    required this.config,
    required PlausibleQueue queue,
    required PlausibleLogger logger,
  }) : _queue = queue,
       _logger = logger,
       _enabled = config.enabled;

  /// Whether tracking is currently active. Starts at [PlausibleConfig.enabled]
  /// and can be flipped at runtime via [setEnabled].
  bool get isEnabled => _enabled;

  /// Runtime kill-switch. Pass `false` to make every subsequent `track*` call
  /// short-circuit (returning [PlausibleSendResult.disabled]) without
  /// touching the network or the queue; pass `true` to resume.
  ///
  /// Useful for opt-in/opt-out consent flows where you don't want to
  /// re-initialize the package on every toggle.
  void setEnabled(bool value) {
    _enabled = value;
    _logger.info(value ? 'tracking enabled' : 'tracking disabled');
  }

  /// Initialize the package. Call this once during app startup (typically in
  /// `main()` after `WidgetsFlutterBinding.ensureInitialized()` and before
  /// `runApp`), then use [Plausible.instance] from anywhere.
  ///
  /// The minimum config is `domain` + `apiHost`:
  ///
  /// ```dart
  /// await Plausible.init(
  ///   domain: 'yourapp.com',
  ///   apiHost: 'https://plausible.io', // or your self-hosted URL
  /// );
  /// ```
  ///
  /// `userAgent` and `defaultProps` are auto-detected from `package_info_plus`
  /// and `device_info_plus` — pass them explicitly only if you want to
  /// override.
  ///
  /// Calling `init` a second time is a no-op (and logs a warning); the
  /// existing instance is returned.
  static Future<Plausible> init({
    required String domain,
    required String apiHost,
    String? userAgent,
    Map<String, String>? defaultProps,
    String? xForwardedFor,
    bool enabled = true,
    bool enableAutoPageviews = false,
    bool disableAutoDeviceProps = false,
    bool debug = false,
    Duration timeout = const Duration(seconds: 10),
    int maxQueueSize = 1000,
    Duration retryInterval = const Duration(minutes: 5),
    List<int>? encryptionKey,
    Dio? dio,
    Logger? logger,
    @visibleForTesting bool skipPlatformDetection = false,
    @visibleForTesting Future<Box<String>> Function()? boxOpener,
    @visibleForTesting Connectivity? connectivity,
  }) async {
    if (_instance != null) {
      _instance!._logger.warn('init() called more than once — ignoring');
      return _instance!;
    }

    final normalizedApiHost = apiHost.replaceAll(RegExp(r'/+$'), '');
    _validateApiHost(normalizedApiHost);
    if (encryptionKey != null && encryptionKey.length != 32) {
      throw ArgumentError.value(
        encryptionKey.length,
        'encryptionKey.length',
        'must be exactly 32 bytes (AES-256)',
      );
    }

    final detected = skipPlatformDetection
        ? const PlausiblePlatformInfo(userAgent: null, defaultProps: {})
        : await _safeDetect(includeDeviceModel: !disableAutoDeviceProps);
    final mergedProps = <String, String>{
      ...detected.defaultProps,
      ...?defaultProps,
    };

    final config = PlausibleConfig(
      domain: domain,
      apiHost: normalizedApiHost,
      userAgent: userAgent ?? detected.userAgent,
      defaultProps: Map.unmodifiable(mergedProps),
      xForwardedFor: xForwardedFor,
      enabled: enabled,
      enableAutoPageviews: enableAutoPageviews,
      debug: debug,
      timeout: timeout,
      maxQueueSize: maxQueueSize,
    );
    final plausibleLogger = PlausibleLogger(enabled: debug, logger: logger);
    if (Uri.parse(normalizedApiHost).scheme == 'http') {
      const msg =
          'apiHost uses http:// — analytics traffic will be sent in '
          'cleartext. Use https:// in production.';
      plausibleLogger.warn(msg);
      debugPrint('[plausible_flutter] WARNING: $msg');
    }
    final client = PlausibleClient(
      config: config,
      logger: plausibleLogger,
      dio: dio,
    );
    final queue = PlausibleQueue(
      config: config,
      client: client,
      logger: plausibleLogger,
      openBox: boxOpener,
      connectivity: connectivity,
      retryInterval: retryInterval,
      encryptionCipher: encryptionKey == null
          ? null
          : HiveAesCipher(encryptionKey),
    );
    await queue.init();
    final plausible = Plausible._internal(
      config: config,
      queue: queue,
      logger: plausibleLogger,
    );
    _instance = plausible;
    plausibleLogger.info('initialized for ${config.domain}');
    return plausible;
  }

  static void _validateApiHost(String apiHost) {
    final uri = Uri.tryParse(apiHost);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError.value(
        apiHost,
        'apiHost',
        'must be a valid http(s) URL (e.g. https://plausible.io)',
      );
    }
  }

  static Future<PlausiblePlatformInfo> _safeDetect({
    required bool includeDeviceModel,
  }) async {
    try {
      return await PlausiblePlatformInfo.detect(
        includeDeviceModel: includeDeviceModel,
      );
    } catch (_) {
      // Platform channels unavailable (e.g. tests) — fall back to empty.
      return const PlausiblePlatformInfo(userAgent: null, defaultProps: {});
    }
  }

  /// Track a screen view.
  ///
  /// [path] is what shows up under *Top Pages* in the dashboard — pass either
  /// a path (`'/settings'`) or a full URL. Paths are normalized against
  /// the configured [PlausibleConfig.domain].
  ///
  /// Optional [referrer] surfaces under *Top Sources*; like [path], it can
  /// be a path or a full URL.
  ///
  /// Returns the resolved [PlausibleSendResult] so you can react (e.g. show a
  /// "saved offline" hint if the event was `queued`).
  Future<PlausibleSendResult> trackPageView(
    String path, {
    String? referrer,
    Map<String, String>? props,
  }) {
    return _send(
      PlausibleEvent(
        name: 'pageview',
        url: _buildUrl(path),
        referrer: _normalizeReferrer(referrer),
        props: props,
      ),
    );
  }

  /// Track a custom event.
  ///
  /// [name] is the event id (`'signup_completed'`, `'contract_signed'`, …)
  /// that shows up in Plausible's *Goals* / *Custom events* reports.
  ///
  /// [path] is optional — pass it if the event is tied to a specific screen
  /// you want to attribute the event to. Defaults to `'/'`.
  ///
  /// [props] are custom properties that become breakdown dimensions in the
  /// Plausible UI. They merge on top of the auto-detected default props.
  Future<PlausibleSendResult> trackEvent(
    String name, {
    String? path,
    Map<String, String>? props,
  }) {
    return _send(
      PlausibleEvent(name: name, url: _buildUrl(path ?? '/'), props: props),
    );
  }

  Future<PlausibleSendResult> _send(PlausibleEvent event) async {
    if (!_enabled) {
      _logger.debug('disabled — skipped ${event.name}');
      return PlausibleSendResult.disabled;
    }
    return _queue.enqueueOrSend(mergeDefaultProps(event, config.defaultProps));
  }

  /// Merges per-event props onto the configured defaults. Per-event keys win
  /// on conflict. Exposed for tests; not part of the public API.
  ///
  /// Always returns an event whose `props` map is owned by the package —
  /// never the caller's mutable map. Sending happens async (queue + Dio
  /// serialization), so if we held a reference to the caller's map a
  /// post-call mutation could leak into the persisted/sent JSON.
  @visibleForTesting
  static PlausibleEvent mergeDefaultProps(
    PlausibleEvent event,
    Map<String, String> defaults,
  ) {
    final eventProps = event.props;
    if (defaults.isEmpty) {
      if (eventProps == null || eventProps.isEmpty) return event;
      // Copy caller's map so a post-call mutation can't leak into the send.
      return PlausibleEvent(
        name: event.name,
        url: event.url,
        referrer: event.referrer,
        props: Map<String, String>.of(eventProps),
        timestamp: event.timestamp,
      );
    }
    if (eventProps == null || eventProps.isEmpty) {
      // `defaults` is the already-unmodifiable map from PlausibleConfig — safe
      // to reuse without copying.
      return PlausibleEvent(
        name: event.name,
        url: event.url,
        referrer: event.referrer,
        props: defaults,
        timestamp: event.timestamp,
      );
    }
    final merged = <String, String>{...defaults, ...eventProps};
    return PlausibleEvent(
      name: event.name,
      url: event.url,
      referrer: event.referrer,
      props: merged,
      timestamp: event.timestamp,
    );
  }

  String _buildUrl(String path) {
    // Already an absolute URL — pass through so callers can override the host
    // (e.g. for deep-link landings or pre-built URLs).
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    final normalized = path.startsWith('/') ? path : '/$path';
    return 'https://${config.domain}$normalized';
  }

  /// Accepts either a full URL or a path; paths get normalized against the
  /// configured domain so Plausible's "Top Sources" report stays consistent.
  /// Empty / null inputs collapse to null so we never ship an empty-string
  /// `referrer` field in the API payload.
  String? _normalizeReferrer(String? referrer) {
    if (referrer == null || referrer.isEmpty) return null;
    if (referrer.startsWith('http://') || referrer.startsWith('https://')) {
      return referrer;
    }
    return _buildUrl(referrer);
  }

  /// Force a drain of any queued events right now.
  ///
  /// You usually don't need to call this — the queue already drains on
  /// connectivity changes, on app resume, and on a periodic timer. Useful
  /// for tests, for "send before sign-out" flows, and when you want to wait
  /// for in-flight events at a specific moment.
  Future<void> flush() => _queue.drain();

  @visibleForTesting
  static Future<void> reset() async {
    await _instance?._queue.dispose();
    _instance = null;
  }
}
