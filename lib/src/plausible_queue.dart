import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/widgets.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'plausible_client.dart';
import 'plausible_config.dart';
import 'plausible_event.dart';
import 'plausible_logger.dart';

const String _boxName = 'plausible_queue';

/// Number of consecutive Hive-open failures we tolerate before giving up on
/// the periodic retry timer (connectivity / lifecycle drains still re-try).
const int _maxOpenFailures = 3;

/// Opens (and lazily initializes) the Hive box used by the queue. Tests inject
/// a fake to avoid hitting `path_provider`.
typedef PlausibleBoxOpener = Future<Box<String>> Function();

Future<Box<String>> _defaultOpenBox() async {
  await Hive.initFlutter('plausible_flutter');
  return Hive.openBox<String>(_boxName);
}

/// Persists events that failed to send and retries them when connectivity
/// returns, on app foreground, and on a slow periodic timer (so a server-side
/// outage with stable connectivity eventually drains).
///
/// Storage: a single Hive box of JSON-encoded events keyed by auto-incremented
/// integers. Iteration order matches insertion (FIFO drain).
class PlausibleQueue with WidgetsBindingObserver {
  final PlausibleConfig _config;
  final PlausibleClient _client;
  final PlausibleLogger _logger;
  final Connectivity _connectivity;
  final PlausibleBoxOpener _openBox;
  final Duration _retryInterval;

  Box<String>? _box;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _retryTimer;
  Future<void>? _drainInFlight;
  Future<void>? _sendLock;

  /// Active per-request cancel tokens. We use a token per send (rather than
  /// reusing one) because Dio registers a `whenCancel.then(...)` listener per
  /// request that never gets released until the token fires — reusing the
  /// same token across thousands of sends leaks listeners.
  final Set<CancelToken> _activeTokens = {};
  int _openFailures = 0;
  bool _draining = false;
  bool _lifecycleBound = false;
  bool _boxOpenAttempted = false;
  bool _disposed = false;

  PlausibleQueue({
    required PlausibleConfig config,
    required PlausibleClient client,
    required PlausibleLogger logger,
    Connectivity? connectivity,
    PlausibleBoxOpener? openBox,
    Duration retryInterval = const Duration(minutes: 5),
  }) : _config = config,
       _client = client,
       _logger = logger,
       _connectivity = connectivity ?? Connectivity(),
       _openBox = openBox ?? _defaultOpenBox,
       _retryInterval = retryInterval;

  Future<void> init() async {
    await _ensureBox();

    _connSub = _connectivity.onConnectivityChanged.listen((results) {
      // Broadcast streams can buffer events that arrive after dispose() set
      // `_disposed = true` but before we cancel the subscription — bail early
      // to avoid kicking off a drain we'll have to bail out of anyway.
      if (_disposed) return;
      if (_hasNetwork(results)) {
        unawaited(drain());
      }
    });

    if (_retryInterval > Duration.zero) {
      _retryTimer = Timer.periodic(_retryInterval, (_) => unawaited(drain()));
    }

    try {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleBound = true;
    } catch (_) {
      // No binding (e.g. unit tests without WidgetsFlutterBinding).
    }

    unawaited(drain());
  }

  /// Opens the Hive box if not already open. Retries on every call until the
  /// open succeeds — so a transient Hive failure at init (disk full, locked
  /// file) doesn't permanently kill the queue. After [_maxOpenFailures]
  /// consecutive failures the periodic retry timer stops (connectivity /
  /// lifecycle still triggers attempts).
  Future<Box<String>?> _ensureBox() async {
    if (_box != null) return _box;
    if (_disposed) return null;
    try {
      _box = await _openBox();
      _openFailures = 0;
      if (!_boxOpenAttempted) {
        _logger.info('queue ready (${_box!.length} pending)');
      } else {
        _logger.info('queue recovered (${_box!.length} pending)');
      }
      _boxOpenAttempted = true;
      return _box;
    } catch (e) {
      _openFailures += 1;
      if (!_boxOpenAttempted) {
        _logger.warn('queue init failed — running without persistence', e);
      }
      _boxOpenAttempted = true;
      if (_openFailures >= _maxOpenFailures && _retryTimer != null) {
        _logger.warn(
          'queue stayed unopenable across $_openFailures attempts — '
          'stopping periodic retry',
        );
        _retryTimer!.cancel();
        _retryTimer = null;
      }
      return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(drain());
    }
  }

  bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  /// Try sending immediately; on transient failure, persist for later.
  /// Returns the resolved [PlausibleSendResult] so callers can react.
  ///
  /// Calls are **chained**: each caller atomically captures the current lock
  /// and installs its own *before* any `await`, so the predecessor each
  /// caller waits on is fixed at call time. That prevents a brand-new call
  /// from cutting in front of already-queued waiters when the current lock
  /// releases — naive while-await mutexes have exactly that race.
  Future<PlausibleSendResult> enqueueOrSend(PlausibleEvent event) async {
    if (_disposed) return PlausibleSendResult.disabled;
    // Synchronous: capture predecessor + install our own lock before any await.
    final previous = _sendLock;
    final completer = Completer<void>();
    _sendLock = completer.future;
    try {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          /* prior call's failure shouldn't poison ours */
        }
      }
      if (_disposed) return PlausibleSendResult.disabled;
      return await _enqueueOrSendLocked(event);
    } finally {
      completer.complete();
      if (identical(_sendLock, completer.future)) _sendLock = null;
    }
  }

  Future<PlausibleSendResult> _enqueueOrSendLocked(PlausibleEvent event) async {
    final box = await _ensureBox();
    if (box != null && box.isNotEmpty) {
      // Queue is non-empty — persist this event behind the existing backlog
      // (FIFO) and let the next drain trigger ship it.
      final persisted = await _persist(event);
      return persisted
          ? PlausibleSendResult.queued
          : PlausibleSendResult.dropped;
    }

    final outcome = await _sendWithToken(event);
    if (_disposed) return PlausibleSendResult.disabled;
    switch (outcome) {
      case PlausibleClientOutcome.success:
        return PlausibleSendResult.success;
      case PlausibleClientOutcome.permanent:
        return PlausibleSendResult.dropped;
      case PlausibleClientOutcome.transient:
        final persisted = await _persist(event);
        // If we couldn't persist (Hive unavailable), the event is *dropped*,
        // not queued — preserve the public contract that `queued` means
        // "persisted and will be retried".
        return persisted
            ? PlausibleSendResult.queued
            : PlausibleSendResult.dropped;
    }
  }

  /// Returns true iff the event was actually written to the box.
  Future<bool> _persist(PlausibleEvent event) async {
    if (_disposed) return false;
    final box = await _ensureBox();
    if (box == null || !box.isOpen) {
      _logger.warn('queue unavailable — dropping event ${event.name}');
      return false;
    }
    if (box.length >= _config.maxQueueSize) {
      final oldestKey = box.keys.first;
      await box.delete(oldestKey);
    }
    await box.add(jsonEncode(event.toJson()));
    _logger.debug('queued ${event.name} (${box.length} pending)');
    return true;
  }

  /// Drain queued events oldest-first. Stops at the first transient failure
  /// to avoid hammering the server while offline. If a drain is already in
  /// flight, callers wait for it to finish and then a fresh drain runs so the
  /// latest queue state is processed (otherwise a coalesced drain could
  /// return without seeing entries enqueued mid-flight).
  Future<void> drain() async {
    while (_drainInFlight != null) {
      await _drainInFlight;
    }
    if (_disposed) return;
    final future = _runDrain();
    _drainInFlight = future;
    try {
      await future;
    } finally {
      _drainInFlight = null;
    }
  }

  Future<void> _runDrain() async {
    if (_disposed) return;
    final box = await _ensureBox();
    if (box == null || !box.isOpen || box.isEmpty || _draining) return;
    _draining = true;
    try {
      final keys = box.keys.toList();
      for (final key in keys) {
        if (_disposed || !box.isOpen) break;
        final raw = box.get(key);
        if (raw == null) continue;
        final PlausibleEvent event;
        try {
          event = PlausibleEvent.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        } catch (e) {
          // Corrupt entry — drop it rather than getting stuck forever.
          _logger.warn('drop corrupt queue entry $key', e);
          if (box.isOpen) await box.delete(key);
          continue;
        }
        final outcome = await _sendWithToken(event);
        if (_disposed || !box.isOpen) break;
        if (outcome == PlausibleClientOutcome.transient) {
          _logger.debug('drain paused (${box.length} remaining)');
          break;
        }
        // Both success and permanent failure remove the entry — there's no
        // point retrying a payload Plausible has explicitly rejected.
        await box.delete(key);
      }
    } finally {
      _draining = false;
    }
  }

  /// Wraps `_client.send` with a per-request [CancelToken] tracked in
  /// [_activeTokens] so [dispose] can fan-cancel without leaking the listener
  /// that Dio attaches via `cancelToken.whenCancel`.
  Future<PlausibleClientOutcome> _sendWithToken(PlausibleEvent event) async {
    final token = CancelToken();
    _activeTokens.add(token);
    try {
      return await _client.send(event, cancelToken: token);
    } finally {
      _activeTokens.remove(token);
    }
  }

  @visibleForTesting
  Future<void>? get pendingDrain => _drainInFlight;

  @visibleForTesting
  bool get hasRetryTimer => _retryTimer != null;

  Future<void> dispose() async {
    _disposed = true;
    // Cancel every in-flight Dio request so dispose doesn't block on the
    // configured timeout (default 10s). Snapshot first since cancellation
    // triggers cleanup that mutates the set.
    for (final token in _activeTokens.toList()) {
      try {
        token.cancel('PlausibleQueue disposed');
      } catch (_) {}
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    if (_lifecycleBound) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
      _lifecycleBound = false;
    }
    await _connSub?.cancel();
    _connSub = null;
    // Wait for any in-flight send/drain to finish before closing the box —
    // otherwise _persist's `box.add(...)` can race `box.close()` and throw.
    // Swallow errors here: an analytics teardown must not propagate.
    try {
      await _sendLock;
    } catch (_) {}
    try {
      await _drainInFlight;
    } catch (_) {}
    try {
      await _box?.close();
    } catch (_) {}
    _box = null;
  }
}
