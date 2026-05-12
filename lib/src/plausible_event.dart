import 'package:meta/meta.dart';

/// A single event sent to Plausible. You usually don't build these directly —
/// `trackEvent` and `trackPageView` construct them under the hood — but they
/// round-trip cleanly through JSON, which is what makes the offline queue
/// possible.
@immutable
class PlausibleEvent {
  /// Event name. Use `'pageview'` for screen views; any other string is a
  /// custom event that shows up in Plausible's *Goals* and *Custom events*
  /// reports.
  final String name;

  /// Synthetic URL representing the screen the event happened on
  /// (e.g. `'https://yourapp.com/checkout/step2'`). Plausible parses the path
  /// out of this URL for the *Top Pages* report.
  final String url;

  /// Optional referrer URL. Surfaced as *Top Sources* in the dashboard.
  final String? referrer;

  /// Optional custom properties. Plausible's UI exposes these as breakdowns
  /// you can filter and group by ("which app version, which screen, which
  /// experiment variant…").
  final Map<String, String>? props;

  /// Wall-clock UTC time the event was created. Used only for FIFO queue
  /// ordering — Plausible records ingestion time on its end and doesn't
  /// accept backdated events.
  final DateTime timestamp;

  PlausibleEvent({
    required this.name,
    required this.url,
    this.referrer,
    this.props,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().toUtc();

  /// Serializes for the Plausible Events API. [timestamp] is intentionally
  /// omitted — the endpoint records ingestion time and has no way to backdate
  /// an event. The local timestamp is kept on the model only for FIFO queue
  /// ordering and round-tripping through [toJson]/[fromJson].
  Map<String, dynamic> toApiPayload(String domain) => {
        'domain': domain,
        'name': name,
        'url': url,
        if (referrer != null) 'referrer': referrer,
        if (props != null && props!.isNotEmpty) 'props': props,
      };

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        if (referrer != null) 'referrer': referrer,
        if (props != null && props!.isNotEmpty) 'props': props,
        'timestamp': timestamp.toIso8601String(),
      };

  factory PlausibleEvent.fromJson(Map<String, dynamic> json) => PlausibleEvent(
        name: json['name'] as String,
        url: json['url'] as String,
        referrer: json['referrer'] as String?,
        props: (json['props'] as Map?)?.map((k, v) => MapEntry(k as String, v as String)),
        timestamp: DateTime.parse(json['timestamp'] as String),
      );
}
