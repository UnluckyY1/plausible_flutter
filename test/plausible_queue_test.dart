import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:plausible_flutter/plausible_flutter.dart';
import 'package:plausible_flutter/src/plausible_client.dart';
import 'package:plausible_flutter/src/plausible_logger.dart';
import 'package:plausible_flutter/src/plausible_queue.dart';

class _FakeConnectivity extends Mock implements Connectivity {
  final _controller = StreamController<List<ConnectivityResult>>.broadcast();

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  void emit(List<ConnectivityResult> r) => _controller.add(r);
  Future<void> shutdown() => _controller.close();
}

void main() {
  late Directory tempDir;
  late int boxCounter;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('plausible_queue_test');
    Hive.init(tempDir.path);
    boxCounter = 0;
  });

  tearDownAll(() async {
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<Box<String>> openFreshBox() async {
    boxCounter += 1;
    return Hive.openBox<String>('test_queue_$boxCounter');
  }

  group('PlausibleQueue', () {
    late _StubAdapter adapter;
    late Dio dio;
    late _FakeConnectivity connectivity;
    late PlausibleClient client;
    late PlausibleQueue queue;
    late Box<String> box;

    const config = PlausibleConfig(
      domain: 'd.example.com',
      apiHost: 'https://h.example.com',
      userAgent: 'TestApp/1.0',
      maxQueueSize: 3,
    );

    setUp(() async {
      adapter = _StubAdapter();
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
        retryInterval: Duration.zero, // disable timer in tests
      );
      await queue.init();
    });

    tearDown(() async {
      // Wrap each tearDown step so a failure here doesn't mask the real test
      // assertion failure (Hive's LateInitializationError on `box` being a
      // common offender if the test failed before init wired the field).
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

    test('successful send leaves the queue empty', () async {
      adapter.responder = (_) => _resp(202, 'ok');
      final result = await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );
      expect(result, PlausibleSendResult.success);
      expect(box.length, 0);
    });

    test('permanent failure (400) is dropped, not queued', () async {
      adapter.responder = (_) => _resp(400, 'bad');
      final result = await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );
      expect(result, PlausibleSendResult.dropped);
      expect(box.length, 0);
    });

    test('transient failure (500) persists for retry', () async {
      adapter.responder = (_) => _resp(500, 'fail');
      final result = await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );
      expect(result, PlausibleSendResult.queued);
      expect(box.length, 1);
    });

    test('at-cap eviction drops the oldest event FIFO', () async {
      adapter.responder = (_) => _resp(500, 'fail');
      for (var i = 0; i < 5; i++) {
        await queue.enqueueOrSend(
          PlausibleEvent(name: 'e$i', url: 'https://d.example.com/x'),
        );
      }
      // maxQueueSize is 3, so only the last 3 survive.
      expect(box.length, 3);
      final names = box.values
          .map(
            (s) => PlausibleEvent.fromJson(
              jsonDecode(s) as Map<String, dynamic>,
            ).name,
          )
          .toList();
      expect(names, ['e2', 'e3', 'e4']);
    });

    test('drain flushes queued events once the server recovers', () async {
      adapter.responder = (_) => _resp(500, 'fail');
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/y'),
      );
      expect(box.length, 2);

      adapter.responder = (_) => _resp(202, 'ok');
      await queue.drain();
      expect(box.length, 0);
    });

    test('drain stops at first transient failure and resumes later', () async {
      // First two persist while server is down.
      adapter.responder = (_) => _resp(500, 'fail');
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'a', url: 'https://d.example.com/x'),
      );
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'b', url: 'https://d.example.com/x'),
      );

      // Server recovers for one event, then fails again.
      var calls = 0;
      adapter.responder = (_) {
        calls += 1;
        return calls == 1 ? _resp(202, 'ok') : _resp(500, 'fail');
      };
      await queue.drain();
      // First event drained, second still queued.
      expect(box.length, 1);

      // Now server fully recovers.
      adapter.responder = (_) => _resp(202, 'ok');
      await queue.drain();
      expect(box.length, 0);
    });

    test('corrupt entries are dropped instead of blocking the queue', () async {
      await box.add('not a json blob');
      adapter.responder = (_) => _resp(202, 'ok');
      await queue.drain();
      expect(box.length, 0);
    });

    test('connectivity change triggers a drain', () async {
      adapter.responder = (_) => _resp(500, 'fail');
      await queue.enqueueOrSend(
        PlausibleEvent(name: 'pageview', url: 'https://d.example.com/x'),
      );
      expect(box.length, 1);

      adapter.responder = (_) => _resp(202, 'ok');
      connectivity.emit([ConnectivityResult.wifi]);
      // Listener fires on the next event-loop turn, then synchronously calls
      // drain() which sets _drainInFlight. Loop the event loop a few times
      // (Duration.zero — no real wait) to give the broadcast stream + listener
      // a chance to install pendingDrain, then await it.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
        if (queue.pendingDrain != null) break;
      }
      await (queue.pendingDrain ?? Future<void>.value());
      expect(box.length, 0);
    });
  });
}

class _StubAdapter implements HttpClientAdapter {
  ResponseBody Function(RequestOptions options) responder = (_) =>
      _resp(200, 'ok');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => responder(options);

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
