import 'package:meta/meta.dart';

import 'platform_info_io.dart'
    if (dart.library.js_interop) 'platform_info_web.dart'
    as impl;

/// Auto-detected platform metadata used to build a Plausible-friendly
/// User-Agent and a set of default props attached to every event.
///
/// Built from `package_info_plus` (app name + version) and `device_info_plus`
/// (OS, OS version, device model). On web the UA is set by the browser and
/// can't be overridden — we only populate `defaultProps`.
@immutable
class PlausiblePlatformInfo {
  /// Browser-style User-Agent string. `null` on web (browsers forbid setting
  /// the header from XHR/fetch).
  final String? userAgent;

  /// Auto-attached props: `app_version`, `platform`, `os_version`,
  /// optionally `device_model`. Merged into every event; per-call props win
  /// on conflict.
  final Map<String, String> defaultProps;

  const PlausiblePlatformInfo({
    required this.userAgent,
    required this.defaultProps,
  });

  static Future<PlausiblePlatformInfo> detect({
    bool includeDeviceModel = true,
  }) => impl.detectPlatformInfo(includeDeviceModel: includeDeviceModel);

  /// Strips characters that would break a User-Agent product token.
  static String sanitize(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');

  /// Builds the Android browser-style User-Agent. When [device] is null the
  /// device-model token is omitted, which is how `disableAutoDeviceProps`
  /// strips the model from the UA string on Android (where it would otherwise
  /// appear inline, not just in `defaultProps`).
  static String buildAndroidUserAgent({
    required String appName,
    required String appVersion,
    required String osVersion,
    String? device,
  }) {
    final product = '$appName/$appVersion';
    if (device == null) {
      return 'Mozilla/5.0 (Linux; Android $osVersion) $product';
    }
    return 'Mozilla/5.0 (Linux; Android $osVersion; $device) $product';
  }
}
