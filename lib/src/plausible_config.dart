import 'package:meta/meta.dart';

/// Immutable snapshot of the configuration passed to [Plausible.init].
///
/// Most apps never construct this directly — `Plausible.init(...)` builds it
/// internally. It's exposed because it can be useful to inspect (e.g. in
/// custom interceptors or for debugging) via `Plausible.instance.config`.
@immutable
class PlausibleConfig {
  /// The site identifier registered in your Plausible dashboard — for example
  /// `'mysite.com'`. Sent in every event payload.
  final String domain;

  /// Base URL of the Plausible instance the events go to. No trailing slash.
  ///
  /// `'https://plausible.io'` for Plausible Cloud, or your self-hosted URL.
  final String apiHost;

  /// User-Agent header sent with every event request. Plausible parses it to
  /// power the *OS / Browser / Device* breakdowns and to drop obvious bots.
  ///
  /// `null` on web — browsers refuse to let JS set this header, so the
  /// browser supplies its own. The dashboard's breakdowns work fine that way.
  final String? userAgent;

  /// Props attached to every event. Auto-populated with `app_version`,
  /// `platform`, `os_version`, and (on mobile) `device_model` unless you pass
  /// `defaultProps` to [Plausible.init] yourself — in which case yours are
  /// merged on top.
  ///
  /// Per-event props passed to `trackEvent(props: ...)` always win on key
  /// conflict.
  final Map<String, String> defaultProps;

  /// Optional `X-Forwarded-For` header value. Useful when your app sits
  /// behind a proxy that doesn't already set it, or for testing region
  /// reports without leaving your desk.
  ///
  /// Leave `null` and Plausible records whatever the connecting IP is.
  final String? xForwardedFor;

  /// When `false`, every `trackEvent` / `trackPageView` call short-circuits
  /// and returns [PlausibleSendResult.disabled] without touching the network
  /// or the offline queue.
  final bool enabled;

  /// When `true`, the default [PlausibleNavigatorObserver] singleton emits
  /// pageviews on every named route push. Observers built via
  /// [Plausible.createNavigatorObserver] ignore this flag.
  final bool enableAutoPageviews;

  /// Toggles the internal logger between `Level.off` and `Level.debug`. Has
  /// no effect when you've injected your own `Logger` via [Plausible.init].
  final bool debug;

  /// Per-request send/receive timeout for the events endpoint.
  final Duration timeout;

  /// Maximum number of events held in the on-disk queue. When the cap is
  /// hit, the oldest events are evicted FIFO so the box can't grow
  /// unbounded.
  final int maxQueueSize;

  const PlausibleConfig({
    required this.domain,
    required this.apiHost,
    this.userAgent,
    this.defaultProps = const {},
    this.xForwardedFor,
    this.enabled = true,
    this.enableAutoPageviews = false,
    this.debug = false,
    this.timeout = const Duration(seconds: 10),
    this.maxQueueSize = 1000,
  });
}
