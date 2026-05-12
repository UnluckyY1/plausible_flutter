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

class _FakeConnectivity extends Mock implements Connectivity {
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream<List<ConnectivityResult>>.empty();
}

void main() {
  late Directory tempDir;
  late _RecordingAdapter adapter;
  late Dio dio;
  late int boxCounter;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('plausible_observer_test');
    Hive.init(tempDir.path);
    boxCounter = 0;
  });

  tearDownAll(() async {
    await Hive.close();
    tempDir.deleteSync(recursive: true);
  });

  setUp(() async {
    adapter = _RecordingAdapter();
    dio = Dio()..httpClientAdapter = adapter;
    await Plausible.init(
      domain: 'd.example.com',
      apiHost: 'https://h.example.com',
      enableAutoPageviews: true,
      dio: dio,
      skipPlatformDetection: true,
      connectivity: _FakeConnectivity(),
      retryInterval: Duration.zero,
      boxOpener: () {
        boxCounter += 1;
        return Hive.openBox<String>('obs_$boxCounter');
      },
    );
  });

  tearDown(() async {
    await Plausible.reset();
  });

  test('default observer skips unnamed routes', () async {
    final observer = PlausibleNavigatorObserver();
    final route = _route(null);
    observer.didPush(route, null);
    await _settle();
    expect(adapter.posts, isEmpty);
  });

  test('default observer tracks named pushes once (no double-count on pop)',
      () async {
    final observer = PlausibleNavigatorObserver();
    final home = _route('/home');
    final detail = _route('/detail');

    observer.didPush(home, null);
    observer.didPush(detail, home);
    observer.didPop(detail, home);
    await _settle();

    expect(adapter.posts.length, 2);
    expect(adapter.posts[0]['url'], 'https://d.example.com/home');
    expect(adapter.posts[1]['url'], 'https://d.example.com/detail');
    expect(adapter.posts[1]['referrer'], 'https://d.example.com/home');
  });

  test('replace tracks the new route with previous as referrer', () async {
    final observer = PlausibleNavigatorObserver();
    final a = _route('/a');
    final b = _route('/b');
    observer.didReplace(newRoute: b, oldRoute: a);
    await _settle();
    expect(adapter.posts.single['url'], 'https://d.example.com/b');
    expect(adapter.posts.single['referrer'], 'https://d.example.com/a');
  });

  test(
      'default observer (respectGlobalFlag: true) no-ops when '
      'enableAutoPageviews is false',
      () async {
    // Re-init with the flag flipped off — the default singleton observer
    // must NOT fire pageviews under this configuration.
    await Plausible.reset();
    await Plausible.init(
      domain: 'd.example.com',
      apiHost: 'https://h.example.com',
      enableAutoPageviews: false,
      dio: dio,
      skipPlatformDetection: true,
      connectivity: _FakeConnectivity(),
      retryInterval: Duration.zero,
      boxOpener: () {
        boxCounter += 1;
        return Hive.openBox<String>('obs_$boxCounter');
      },
    );
    Plausible.navigatorObserver.didPush(_route('/home'), null);
    await _settle();
    expect(adapter.posts, isEmpty);

    // Sanity: a custom observer (respectGlobalFlag: false by default) should
    // still fire under the exact same config — proves the flag-gating is
    // limited to the default singleton.
    final custom = Plausible.createNavigatorObserver();
    custom.didPush(_route('/contracts'), null);
    await _settle();
    expect(adapter.posts.single['url'], 'https://d.example.com/contracts');
  });

  test('custom filter can rename and skip routes', () async {
    final observer = PlausibleNavigatorObserver(filter: (route) {
      final name = route.settings.name;
      if (name == '/secret') return null;
      return name == null ? null : 'screen:$name';
    });
    observer.didPush(_route('/home'), null);
    observer.didPush(_route('/secret'), _route('/home'));
    await _settle();
    expect(adapter.posts.length, 1);
    expect(adapter.posts.single['url'], 'https://d.example.com/screen:/home');
  });
}

/// Yields the event loop (microtasks + timer queue) a handful of times so
/// the trackPageView → _send → enqueueOrSend → _client.send chain has a
/// chance to complete. `Duration.zero` doesn't actually wait — it just
/// rounds-robins through the event loop — so this is independent of
/// real-time pacing.
Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Route<dynamic> _route(String? name) {
  return PageRouteBuilder<void>(
    settings: RouteSettings(name: name),
    pageBuilder: (a, b, c) => const SizedBox.shrink(),
  );
}

class _RecordingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> posts = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.data is Map) {
      posts.add(Map<String, dynamic>.from(options.data as Map));
    }
    return ResponseBody.fromBytes(
      utf8.encode('ok'),
      202,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
