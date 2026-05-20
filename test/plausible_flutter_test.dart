import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plausible_flutter/plausible_flutter.dart';
import 'package:plausible_flutter/src/plausible_client.dart';
import 'package:plausible_flutter/src/plausible_logger.dart';

void main() {
  group('PlausibleEvent', () {
    test('toApiPayload includes domain and required fields', () {
      final event = PlausibleEvent(
        name: 'pageview',
        url: 'https://app.example.com/home',
      );

      final payload = event.toApiPayload('app.example.com');

      expect(payload['domain'], 'app.example.com');
      expect(payload['name'], 'pageview');
      expect(payload['url'], 'https://app.example.com/home');
      expect(payload.containsKey('referrer'), isFalse);
      expect(payload.containsKey('props'), isFalse);
    });

    test('toApiPayload includes optional referrer and props when provided', () {
      final event = PlausibleEvent(
        name: 'contract_signed',
        url: 'https://app.example.com/contracts',
        referrer: 'https://app.example.com/home',
        props: {'kind': 'pdf'},
      );

      final payload = event.toApiPayload('app.example.com');

      expect(payload['referrer'], 'https://app.example.com/home');
      expect(payload['props'], {'kind': 'pdf'});
    });

    test('roundtrips through json', () {
      final original = PlausibleEvent(
        name: 'pageview',
        url: 'https://app.example.com/x',
        referrer: 'r',
        props: {'a': '1'},
      );

      final restored = PlausibleEvent.fromJson(original.toJson());

      expect(restored.name, original.name);
      expect(restored.url, original.url);
      expect(restored.referrer, original.referrer);
      expect(restored.props, original.props);
      expect(
        restored.timestamp.toIso8601String(),
        original.timestamp.toIso8601String(),
      );
    });
  });

  group('PlausibleConfig', () {
    test('defaults are sensible', () {
      const config = PlausibleConfig(
        domain: 'd',
        apiHost: 'https://h',
        userAgent: 'ua',
      );

      expect(config.enabled, isTrue);
      expect(config.enableAutoPageviews, isFalse);
      expect(config.debug, isFalse);
      expect(config.maxQueueSize, 1000);
      expect(config.timeout, const Duration(seconds: 10));
      expect(config.xForwardedFor, isNull);
      expect(config.defaultProps, isEmpty);
    });

    test('userAgent and defaultProps can both be omitted (null/empty)', () {
      const config = PlausibleConfig(domain: 'd', apiHost: 'https://h');
      expect(config.userAgent, isNull);
      expect(config.defaultProps, isEmpty);
    });
  });

  group('Plausible.mergeDefaultProps', () {
    test(
      'returns event unchanged when defaults are empty and event has no props',
      () {
        final event = PlausibleEvent(name: 'pageview', url: 'https://app/x');
        final merged = Plausible.mergeDefaultProps(event, const {});
        expect(identical(merged, event), isTrue);
      },
    );

    test(
      'defensively copies event.props when defaults are empty (mutation safety)',
      () {
        final props = <String, String>{'a': '1'};
        final event = PlausibleEvent(
          name: 'pageview',
          url: 'https://app/x',
          props: props,
        );
        final merged = Plausible.mergeDefaultProps(event, const {});
        // Equal contents, but NOT the same map — a caller-side mutation of
        // `props` must not leak into the persisted/sent event.
        expect(merged.props, props);
        expect(identical(merged.props, props), isFalse);
        props['a'] = 'MUTATED';
        expect(merged.props!['a'], '1');
      },
    );

    test('attaches defaults when event has no props', () {
      final event = PlausibleEvent(name: 'pageview', url: 'https://app/x');
      final merged = Plausible.mergeDefaultProps(event, const {
        'app_version': '1.2.3',
        'platform': 'ios',
      });
      expect(merged.props, {'app_version': '1.2.3', 'platform': 'ios'});
    });

    test('per-event props override defaults on conflict', () {
      final event = PlausibleEvent(
        name: 'contract_signed',
        url: 'https://app/x',
        props: {'platform': 'override', 'extra': 'ok'},
      );
      final merged = Plausible.mergeDefaultProps(event, const {
        'app_version': '1.2.3',
        'platform': 'ios',
      });
      expect(merged.props, {
        'app_version': '1.2.3',
        'platform': 'override',
        'extra': 'ok',
      });
    });

    test('preserves event identity (name, url, referrer, timestamp)', () {
      final ts = DateTime.utc(2026, 1, 1);
      final event = PlausibleEvent(
        name: 'pageview',
        url: 'https://app/x',
        referrer: 'r',
        timestamp: ts,
      );
      final merged = Plausible.mergeDefaultProps(event, const {'k': 'v'});
      expect(merged.name, 'pageview');
      expect(merged.url, 'https://app/x');
      expect(merged.referrer, 'r');
      expect(merged.timestamp, ts);
    });
  });

  group('PlausibleClient', () {
    late _CapturingAdapter adapter;
    late Dio dio;

    setUp(() {
      adapter = _CapturingAdapter();
      dio = Dio()..httpClientAdapter = adapter;
    });

    test('sends User-Agent and target URL on every request', () async {
      const config = PlausibleConfig(
        domain: 'app.example.com',
        apiHost: 'https://plausible.example.com',
        userAgent: 'TestApp/1.0',
      );
      final client = PlausibleClient(
        config: config,
        logger: PlausibleLogger(),
        dio: dio,
      );

      final result = await client.send(
        PlausibleEvent(name: 'pageview', url: 'https://app.example.com/x'),
      );

      expect(result, PlausibleClientOutcome.success);
      expect(
        adapter.lastRequest!.uri.toString(),
        'https://plausible.example.com/api/event',
      );
      expect(adapter.lastRequest!.headers['User-Agent'], 'TestApp/1.0');
      expect(
        adapter.lastRequest!.headers.containsKey('X-Forwarded-For'),
        isFalse,
      );
    });

    test(
      'omits User-Agent header when config.userAgent is null (web case)',
      () async {
        const config = PlausibleConfig(
          domain: 'app.example.com',
          apiHost: 'https://plausible.example.com',
          // userAgent omitted on purpose — simulates web build.
        );
        final client = PlausibleClient(
          config: config,
          logger: PlausibleLogger(),
          dio: dio,
        );

        await client.send(
          PlausibleEvent(name: 'pageview', url: 'https://app.example.com/x'),
        );

        expect(adapter.lastRequest!.headers.containsKey('User-Agent'), isFalse);
      },
    );

    test('forwards X-Forwarded-For when configured', () async {
      const config = PlausibleConfig(
        domain: 'app.example.com',
        apiHost: 'https://plausible.example.com',
        userAgent: 'TestApp/1.0',
        xForwardedFor: '203.0.113.42',
      );
      final client = PlausibleClient(
        config: config,
        logger: PlausibleLogger(),
        dio: dio,
      );

      await client.send(
        PlausibleEvent(name: 'pageview', url: 'https://app.example.com/x'),
      );

      expect(adapter.lastRequest!.headers['X-Forwarded-For'], '203.0.113.42');
    });

    test('classifies 4xx (not 408/429) as permanent failure', () async {
      adapter.responder = (_) => _resp(400, '{"error":"bad"}');
      const config = PlausibleConfig(
        domain: 'd',
        apiHost: 'https://h',
        userAgent: 'ua',
      );
      final client = PlausibleClient(
        config: config,
        logger: PlausibleLogger(),
        dio: dio,
      );

      final result = await client.send(
        PlausibleEvent(name: 'pageview', url: 'https://d/x'),
      );

      expect(result, PlausibleClientOutcome.permanent);
    });

    test(
      'pins validateStatus so caller-supplied Dio cannot bypass it',
      () async {
        // Hostile setup: caller configures Dio to treat every status as success.
        dio.options.validateStatus = (_) => true;
        adapter.responder = (_) => _resp(400, 'bad');
        const config = PlausibleConfig(
          domain: 'd',
          apiHost: 'https://h',
          userAgent: 'ua',
        );
        final client = PlausibleClient(
          config: config,
          logger: PlausibleLogger(),
          dio: dio,
        );

        final result = await client.send(
          PlausibleEvent(name: 'pageview', url: 'https://d/x'),
        );
        // The 400 must still classify as permanent failure, not success.
        expect(result, PlausibleClientOutcome.permanent);
      },
    );

    test('classifies 5xx and 429 as transient failure', () async {
      const config = PlausibleConfig(
        domain: 'd',
        apiHost: 'https://h',
        userAgent: 'ua',
      );
      final client = PlausibleClient(
        config: config,
        logger: PlausibleLogger(),
        dio: dio,
      );

      adapter.responder = (_) => _resp(500, '');
      expect(
        await client.send(PlausibleEvent(name: 'pageview', url: 'https://d/x')),
        PlausibleClientOutcome.transient,
      );

      adapter.responder = (_) => _resp(429, '');
      expect(
        await client.send(PlausibleEvent(name: 'pageview', url: 'https://d/x')),
        PlausibleClientOutcome.transient,
      );
    });
  });
}

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? lastRequest;
  ResponseBody Function(RequestOptions options) responder = (_) =>
      _resp(200, 'ok');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
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
