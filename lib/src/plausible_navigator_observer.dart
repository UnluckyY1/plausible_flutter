import 'dart:async';

import 'package:flutter/widgets.dart';

import 'plausible.dart';

/// Decides whether a route should produce a pageview, and under what name.
/// Return `null` to skip the event entirely.
///
/// ```dart
/// PlausibleRouteFilter myFilter = (route) {
///   final name = route.settings.name;
///   if (name == null || name.startsWith('/internal/')) return null;
///   return name;
/// };
/// ```
typedef PlausibleRouteFilter = String? Function(Route<dynamic> route);

/// A `NavigatorObserver` that fires a Plausible `pageview` for every route
/// push.
///
/// Drop the default singleton into `MaterialApp.navigatorObservers`:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [Plausible.navigatorObserver],
///   // ...
/// )
/// ```
///
/// By default only routes with a non-empty `settings.name` are tracked
/// (so `showDialog` and anonymous routes don't flood the dashboard with
/// `/` pageviews), and only on push/replace — pops don't double-count the
/// route you're returning to. The previous route's name is forwarded as
/// `referrer` so Plausible's *Top Sources* report works.
///
/// Pass a custom [filter] to rename or skip specific routes:
///
/// ```dart
/// Plausible.createNavigatorObserver(
///   filter: (route) {
///     final name = route.settings.name;
///     return name == '/secret' ? null : name;
///   },
/// );
/// ```
///
/// **One observer per `Navigator`.** `NavigatorObserver` is stateful — it
/// stores the `Navigator` it's attached to in a field that Flutter
/// overwrites on each attach. Sharing the singleton across multiple
/// Navigators (tabbed apps, nested routers) silently breaks the earlier
/// attachment. For multi-Navigator apps, build a fresh observer per
/// Navigator with [Plausible.createNavigatorObserver].
class PlausibleNavigatorObserver extends NavigatorObserver {
  final PlausibleRouteFilter filter;

  /// When `true`, the observer only fires events while
  /// `PlausibleConfig.enableAutoPageviews` is `true`.
  ///
  /// The default [Plausible.navigatorObserver] sets this to `true` so the
  /// `enableAutoPageviews` init flag can disable it without unwiring it.
  /// Observers built via [Plausible.createNavigatorObserver] default to
  /// `false` — if you're constructing one explicitly, you've opted in.
  final bool respectGlobalFlag;

  PlausibleNavigatorObserver({
    PlausibleRouteFilter? filter,
    this.respectGlobalFlag = false,
  }) : filter = filter ?? _defaultFilter;

  static String? _defaultFilter(Route<dynamic> route) {
    final name = route.settings.name;
    if (name == null || name.isEmpty) return null;
    return name;
  }

  void _track(Route<dynamic>? route, Route<dynamic>? previousRoute) {
    if (route == null) return;
    if (!Plausible.isInitialized) return;
    if (respectGlobalFlag && !Plausible.instance.config.enableAutoPageviews) {
      return;
    }
    final name = filter(route);
    if (name == null) return;
    final referrer = previousRoute != null ? filter(previousRoute) : null;
    unawaited(Plausible.instance.trackPageView(name, referrer: referrer));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _track(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _track(newRoute, oldRoute);
  }
}
