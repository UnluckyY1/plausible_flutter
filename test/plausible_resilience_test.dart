import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plausible_flutter/plausible_flutter.dart';
import 'package:plausible_flutter/src/platform_info.dart';
import 'package:plausible_flutter/src/plausible_client.dart';
import 'package:plausible_flutter/src/plausible_logger.dart';
import 'package:plausible_flutter/src/plausible_queue.dart';

class _FakeConnectivity extends Mock implements Connectivity {
  final _controller = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  Future<void> shutdown() => _controller.close();
}

void main() {
  late Directory tempDir;
  late int boxCounter;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('plausible_resilience_test');
    Hive.init(tempDir.path);
    boxCounter = 0;
  });

  tearDownAll(() async {
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<Box<String>> openFreshBox() {
    boxCounter += 1;
    return Hive.openBox<String>('res_$boxCounter');
  }

  group('PlausiblePlatformInfo.buildAndroidUserAgent', () {
    test('includes device when supplied', () {
      final ua = PlausiblePlatformInfo.buildAndroidUserAgent(
        appName: 'Creator',
        appVersion: '4.8.1',
        osVersion: '14',
        device: 'SM-G991B',
      );
      expect(ua, 'Mozilla/5.0 (Linux; Android 14; SM-G991B) Creator/4.8.1');
    });

    test('drops device segment when null (disableAutoDeviceProps path)', () {
      final ua = PlausiblePlatformInfo.buildAndroidUserAgent(
        appName: 'Creator',
        appVersion: '4.8.1',
        osVersion: '14',
        device: null,
      );
      expect(ua, 'Mozilla/5.0 (Linux; Android 14) Creator/4.8.1');
      expect(ua.contains('SM-'), isFalse);
    });
  });

  group('Plausible facade resilience', () {
    late _RecordingAdapter adapter;
    late Dio dio;

    setUp(() {
      adapter = _RecordingAdapter();
      dio = Dio()..httpClientAdapter = adapter;
    });

    tearDown(() async {
      await Plausible.reset();
    });

    Future<void> initPlausible({
      bool enabled = true,
      Future<Box<String>> Function()? boxOpener,
    }) async {
      await Plausible.init(
        domain: 'd.example.com',
        apiHost: 'https://h.example.com',
        enabled: enabled,
        dio: dio,
        skipPlatformDetection: true,
        connectivity: _FakeConnectivity(),
        retryInterval: Duration.zero,
        boxOpener: boxOpener ?? openFreshBox,
      );
    }

    test(
      'enabled: false short-circuits — adapter never receives a request',
      () async {
        await initPlausible(enabled: false);
        final r = await Plausible.instance.trackEvent('demo');
        expect(r, PlausibleSendResult.disabled);
        expect(adapter.posts, isEmpty);
      },
    );

    test('setEnabled(false) at runtime suppresses subsequent events', () async {
      await initPlausible();
      await Plausible.instance.trackEvent('first');
      Plausible.instance.setEnabled(false);
      await Plausible.instance.trackEvent('second');
      Plausible.instance.setEnabled(true);
      await Plausible.instance.trackEvent('third');

      expect(adapter.posts.map((p) => p['name']).toList(), ['first', 'third']);
    });

    test(
      'Hive open failure does not crash init — events become no-ops',
      () async {
        await initPlausible(
          boxOpener: () async => throw StateError('disk full'),
        );

        final r = await Plausible.instance.trackEvent('demo');
        // Live network send still happens — adapter returns 202 by default.
        expect(adapter.posts.single['name'], 'demo');
        expect(r, PlausibleSendResult.success);
      },
    );

    test(
      'Hive open failure: transient send is reported as dropped, not queued',
      () async {
        adapter.responder = (_) => _resp(500, 'fail');
        await initPlausible(
          boxOpener: () async => throw StateError('disk full'),
        );

        final r = await Plausible.instance.trackEvent('demo');
        // No persistence available, so the event is genuinely lost — the
        // public contract for `queued` is "persisted and will be retried", so
        // we must report `dropped` here, not lie.
        expect(r, PlausibleSendResult.dropped);
      },
    );

    test('absolute URL passes through _buildUrl unchanged', () async {
      await initPlausible();
      await Plausible.instance.trackPageView('https://other.example.com/x');
      expect(adapter.posts.single['url'], 'https://other.example.com/x');
    });

    test('relative path is prefixed with the configured domain', () async {
      await initPlausible();
      await Plausible.instance.trackPageView('/contracts');
      expect(adapter.posts.single['url'], 'https://d.example.com/contracts');
    });

    test(
      'empty xForwardedFor / userAgent do not produce empty headers',
      () async {
        // Re-init with explicit empty strings — both should be omitted, not
        // sent as empty-value headers.
        await Plausible.init(
          domain: 'd.example.com',
          apiHost: 'https://h.example.com',
          userAgent: '',
          xForwardedFor: '',
          dio: dio,
          skipPlatformDetection: true,
          connectivity: _FakeConnectivity(),
          retryInterval: Duration.zero,
          boxOpener: openFreshBox,
        );
        await Plausible.instance.trackEvent('demo');
        expect(adapter.headers.last.containsKey('User-Agent'), isFalse);
        expect(adapter.headers.last.containsKey('X-Forwarded-For'), isFalse);
      },
    );

    test('empty referrer string is dropped from the payload', () async {
      await initPlausible();
      await Plausible.instance.trackPageView('/home', referrer: '');
      // Must not appear at all (and must definitely not be sent as empty).
      expect(adapter.posts.single.containsKey('referrer'), isFalse);
    });

    test(
      'caller-mutated props map does not leak into the sent payload',
      () async {
        await initPlausible();
        final props = <String, String>{'kind': 'before-mutation'};
        // Start the send but mutate the caller's map immediately, before the
        // send future resolves. mergeDefaultProps must have copied synchronously.
        final sendFuture = Plausible.instance.trackEvent('demo', props: props);
        props['kind'] = 'AFTER-MUTATION';
        await sendFuture;
        final captured = adapter.posts.single['props'] as Map;
        expect(captured['kind'], 'before-mutation');
      },
    );
  });

  group('PlausibleQueue lifecycle / retry triggers', () {
    late _RecordingAdapter adapter;
    late Dio dio;
    late _FakeConnectivity connectivity;
    late PlausibleClient client;
    late PlausibleQueue queue;
    late Box<String> box;

    const config = PlausibleConfig(
      domain: 'd.example.com',
      apiHost: 'https://h.example.com',
      userAgent: 'TestApp/1.0',
      maxQueueSize: 100,
    );

    Future<void> makeQueue({Duration? retryInterval}) async {
      adapter = _RecordingAdapter();
      dio = Dio()..httpClientAdapter = adapter;
      connectivity = _FakeConnectivity();
      client = PlausibleClient(
        config: config,
        logger: PlausibleLogger(),
        dio: dio,
      );
      queue = PlausibleQueue(
        config: config,
        client: client,
        logger: PlausibleLogger(),
        connectivity: connectivity,
        openBox: () async {
          box = await openFreshBox();
          return box;
        },
        retryInterval: retryInterval ?? Duration.zero,
      );
      await queue.init();
    }

    tearDown(() async {
      try {
        await queue.dispose();
      } catch (_) {}
      try {
        await connectivity.shutdown();
      } catch (_) {}
      try {
        if (box.isOpen) await box.deleteFromDisk();
      } catch (_) {}
    });

    test('retry timer is scheduled when retryInterval > 0', () async {
      await makeQueue(retryInterval: const Duration(minutes: 5));
      expect(queue.hasRetryTimer, isTrue);
    });

    test('retry timer is NOT scheduled when retryInterval is zero', () async {
      await makeQueue(retryInterval: Duration.zero);
      expect(queue.hasRetryTimer, isFalse);
    });

    test('AppLifecycleState.resumed drains the queue', () async {
      await makeQueue();
      adapter.responder = (_) => _resp(500, 'fail');
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );
      expect(box.length, 1);

      adapter.responder = (_) => _resp(202, 'ok');
      queue.didChangeAppLifecycleState(AppLifecycleState.resumed);
      // didChangeAppLifecycleState synchronously calls drain(), which sets
      // _drainInFlight before its first await. Await it deterministically.
      await (queue.pendingDrain ?? Future<void>.value());
      expect(box.length, 0);
    });

    test('AppLifecycleState.paused does not drain', () async {
      await makeQueue();
      adapter.responder = (_) => _resp(500, 'fail');
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );

      adapter.responder = (_) => _resp(202, 'ok');
      queue.didChangeAppLifecycleState(AppLifecycleState.paused);
      // Should not have kicked off a drain.
      expect(queue.pendingDrain, isNull);
      expect(box.length, 1);
    });

    test('FIFO is preserved when enqueueing during an outage', () async {
      await makeQueue();
      adapter.responder = (_) => _resp(500, 'fail');

      // First call: queue empty → tries network, persists on failure.
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'a', url: 'https://d.example.com/x'),
      );
      // Second call: queue non-empty → short-circuits to persist (no leapfrog).
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'b', url: 'https://d.example.com/x'),
      );
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'c', url: 'https://d.example.com/x'),
      );

      expect(box.length, 3);

      // Server recovers; verify drain order matches insertion order.
      adapter.responder = (_) => _resp(202, 'ok');
      adapter.posts.clear();
      await queue.drain();
      expect(adapter.posts.map((p) => p['name']).toList(), ['a', 'b', 'c']);
    });

    test(
      'concurrent enqueueOrSend calls are serialized (FIFO under race)',
      () async {
        await makeQueue();
        adapter.responder = (_) => _resp(500, 'fail');

        // Fire three calls without awaiting — the mutex must serialize them so
        // they persist in invocation order, not network-response order.
        final futures = [
          queue.enqueueOrSend(
            PlausibleEvent(name: 'a', url: 'https://d.example.com/x'),
          ),
          queue.enqueueOrSend(
            PlausibleEvent(name: 'b', url: 'https://d.example.com/x'),
          ),
          queue.enqueueOrSend(
            PlausibleEvent(name: 'c', url: 'https://d.example.com/x'),
          ),
        ];
        await Future.wait(futures);

        adapter.responder = (_) => _resp(202, 'ok');
        adapter.posts.clear();
        await queue.drain();
        expect(adapter.posts.map((p) => p['name']).toList(), ['a', 'b', 'c']);
      },
    );

    test(
      'FIFO survives a re-entrant call from a prior send completion',
      () async {
        // Scenario the chained-mutex must defend: A holds the lock, B is queued
        // behind A. When A finishes, its caller (synchronously, before B's
        // microtask runs) fires C. With a naive while-await mutex C cuts ahead
        // of B; with chained promises it appends behind B.
        await makeQueue();
        adapter.responder = (_) => _resp(500, 'fail');

        late final Future<PlausibleSendResult> aFuture;
        late final Future<PlausibleSendResult> bFuture;
        Future<PlausibleSendResult>? cFuture;
        aFuture = queue.enqueueOrSend(
          PlausibleEvent(name: 'a', url: 'https://d.example.com/x'),
        );
        bFuture = queue.enqueueOrSend(
          PlausibleEvent(name: 'b', url: 'https://d.example.com/x'),
        );
        // Schedule C *synchronously* in A's completion continuation. Because
        // the chained mutex captured `_sendLock` before any await, C will
        // append after B, not jump ahead.
        // ignore: unawaited_futures
        aFuture.then((_) {
          cFuture = queue.enqueueOrSend(
            PlausibleEvent(name: 'c', url: 'https://d.example.com/x'),
          );
        });
        await Future.wait([aFuture, bFuture]);
        // Wait for C if it was scheduled.
        if (cFuture != null) await cFuture;

        adapter.responder = (_) => _resp(202, 'ok');
        adapter.posts.clear();
        await queue.drain();
        expect(adapter.posts.map((p) => p['name']).toList(), ['a', 'b', 'c']);
      },
    );

    test(
      'dispose() cancels in-flight Dio requests and returns promptly',
      () async {
        // Swap in an adapter that hangs forever unless its cancel token fires.
        // Without the CancelToken plumbing, dispose would block on the
        // configured timeout (10s); with it, this should be ~instant.
        final hangingAdapter = _HangingAdapter();
        adapter = _RecordingAdapter(); // ignored; we override dio's adapter
        dio = Dio()..httpClientAdapter = hangingAdapter;
        connectivity = _FakeConnectivity();
        client = PlausibleClient(
          config: config,
          logger: PlausibleLogger(),
          dio: dio,
        );
        queue = PlausibleQueue(
          config: config,
          client: client,
          logger: PlausibleLogger(),
          connectivity: connectivity,
          openBox: () async {
            box = await openFreshBox();
            return box;
          },
          retryInterval: Duration.zero,
        );
        await queue.init();

        // Kick off a send that will hang on the network until cancellation.
        // ignore: unawaited_futures
        queue.enqueueOrSend(
          PlausibleEvent(name: 'demo', url: 'https://d.example.com/x'),
        );
        // Yield so the adapter's fetch() runs and parks on cancelToken.whenCancel.
        await Future<void>.value();
        await Future<void>.value();

        final stopwatch = Stopwatch()..start();
        await queue.dispose();
        stopwatch.stop();
        // The real failure mode without a CancelToken is dispose blocking on
        // the full request timeout (`config.timeout`, default 10s). 2s is
        // comfortable headroom for a CI runner under contention while still
        // catching the regression.
        expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      },
    );

    test('corrupt entry doesn\'t block valid entries after it', () async {
      await makeQueue();
      adapter.responder = (_) => _resp(202, 'ok');

      // Insert: valid, corrupt, valid — drain should send the two valids.
      await box.add(
        jsonEncode(
          PlausibleEvent(
            name: 'before',
            url: 'https://d.example.com/x',
          ).toJson(),
        ),
      );
      await box.add('totally not json');
      await box.add(
        jsonEncode(
          PlausibleEvent(
            name: 'after',
            url: 'https://d.example.com/x',
          ).toJson(),
        ),
      );

      await queue.drain();
      expect(box.length, 0);
      expect(adapter.posts.map((p) => p['name']).toList(), ['before', 'after']);
    });
  });
}

/// Adapter that parks on the request's cancellation future and only completes
/// (with a cancellation DioException) when the CancelToken fires.
class _HangingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (cancelFuture != null) {
      try {
        await cancelFuture;
      } catch (_) {}
    } else {
      // No cancel future — fall back to a future that never completes.
      await Completer<void>().future;
    }
    throw DioException.requestCancelled(
      requestOptions: options,
      reason: 'cancelled by test',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> posts = [];
  final List<Map<String, List<String>>> headers = [];
  ResponseBody Function(RequestOptions options) responder = (_) =>
      _resp(202, 'ok');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.data is Map) {
      posts.add(Map<String, dynamic>.from(options.data as Map));
    }
    headers.add(
      options.headers.map(
        (k, v) =>
            MapEntry(k, v is List ? v.cast<String>() : <String>[v.toString()]),
      ),
    );
    return responder(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _resp(int status, String body) {
  return ResponseBody.fromBytes(
    utf8.encode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
}
