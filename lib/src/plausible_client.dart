import 'package:dio/dio.dart';

import 'native_adapter_io.dart'
    if (dart.library.js_interop) 'native_adapter_web.dart';
import 'plausible_config.dart';
import 'plausible_event.dart';
import 'plausible_logger.dart';

/// What happened to a `trackEvent` / `trackPageView` call.
///
/// You don't have to inspect this — `await trackEvent(...)` is fine — but
/// it's there if you want to surface "queued offline" UI, retry logic, or
/// assert in tests.
enum PlausibleSendResult {
  /// 2xx response. The event reached Plausible and was accepted.
  success,

  /// The event is sitting safely on disk and will be retried automatically
  /// on the next drain trigger (connectivity change, app resume, periodic
  /// timer, or an explicit [Plausible.flush]).
  ///
  /// Returned both when the live POST failed transiently *and* when the
  /// queue was already non-empty and we appended the event behind the
  /// backlog to preserve FIFO order.
  queued,

  /// The event won't reach Plausible and won't be retried. Two paths:
  ///
  ///   - Plausible returned a 4xx (≠ 408 / 429) — the payload is invalid
  ///     and retrying wouldn't help.
  ///   - The live send failed transiently *and* the offline queue is
  ///     unavailable (Hive can't open the box — disk full, IndexedDB
  ///     disabled in private-mode Safari, …). The event is genuinely lost.
  dropped,

  /// Tracking is off — the call returned immediately without touching the
  /// network or the queue. Either you passed `enabled: false` to
  /// [Plausible.init] or you flipped it at runtime with
  /// [Plausible.setEnabled].
  disabled,
}

/// Result of a single low-level HTTP attempt. Distinct from
/// [PlausibleSendResult] because the queue layer needs to distinguish
/// "transient — please persist" from "queued — already persisted".
/// Internal — consumers should use [PlausibleSendResult].
enum PlausibleClientOutcome { success, transient, permanent }

/// Thin wrapper around Dio for the Plausible Events API.
///
/// Headers and the request URL are always built from [PlausibleConfig], so
/// callers that inject a custom Dio (e.g. tests) don't need to re-do this
/// configuration.
class PlausibleClient {
  final PlausibleConfig _config;
  final PlausibleLogger _logger;
  final Dio _dio;

  PlausibleClient({
    required PlausibleConfig config,
    required PlausibleLogger logger,
    Dio? dio,
  })  : _config = config,
        _logger = logger,
        _dio = dio ?? _buildDefaultDio(config);

  static Dio _buildDefaultDio(PlausibleConfig config) {
    final dio = Dio(BaseOptions(
      connectTimeout: config.timeout,
      receiveTimeout: config.timeout,
      sendTimeout: config.timeout,
    ));
    applyNativeAdapter(dio);
    return dio;
  }

  Future<PlausibleClientOutcome> send(
    PlausibleEvent event, {
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post(
        '${_config.apiHost}/api/event',
        data: event.toApiPayload(_config.domain),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.plain,
          // Pin validateStatus inside the request so a consumer-supplied Dio
          // can't change how we classify responses.
          validateStatus: (_) => true,
          // Re-apply timeouts at the request level so a consumer-injected Dio
          // (which doesn't have our BaseOptions) still honors config.timeout.
          sendTimeout: _config.timeout,
          receiveTimeout: _config.timeout,
          headers: {
            // On web the browser sets User-Agent itself and rejects overrides.
            if (_config.userAgent != null && _config.userAgent!.isNotEmpty)
              'User-Agent': _config.userAgent,
            if (_config.xForwardedFor != null &&
                _config.xForwardedFor!.isNotEmpty)
              'X-Forwarded-For': _config.xForwardedFor,
          },
        ),
      );
      return _classify(event, response.statusCode, response.data);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _logger.debug('send cancelled for ${event.name}');
        return PlausibleClientOutcome.transient;
      }
      // Surface the exception type when `message` is null — happens for
      // sandbox/entitlement denials, CORS, TLS, and other connection-layer
      // failures where Dio doesn't get a message back. `null` alone is
      // useless when debugging "why is the dashboard empty?".
      final detail = e.message ?? '${e.type} (${e.error ?? 'no detail'})';
      _logger.warn('retry later ${event.name}: $detail');
      return PlausibleClientOutcome.transient;
    } catch (e) {
      _logger.error('unexpected error sending ${event.name}', e);
      return PlausibleClientOutcome.transient;
    }
  }

  PlausibleClientOutcome _classify(
      PlausibleEvent event, int? status, Object? body) {
    if (status == null) {
      _logger.warn('retry later ${event.name}: no status');
      return PlausibleClientOutcome.transient;
    }
    if (status >= 200 && status < 300) {
      _logger.debug('sent ${event.name} → $status');
      return PlausibleClientOutcome.success;
    }
    if (status >= 400 && status < 500 && status != 408 && status != 429) {
      _logger.warn('drop ${event.name}: $status $body');
      return PlausibleClientOutcome.permanent;
    }
    _logger.warn('retry later ${event.name}: $status');
    return PlausibleClientOutcome.transient;
  }
}

