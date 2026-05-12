import 'package:package_info_plus/package_info_plus.dart';

import 'platform_info.dart';

Future<PlausiblePlatformInfo> detectPlatformInfo({
  bool includeDeviceModel = true,
}) async {
  final pkg = await PackageInfo.fromPlatform();
  final appVersion = pkg.version.isEmpty ? '0.0.0' : pkg.version;
  return PlausiblePlatformInfo(
    userAgent: null,
    defaultProps: {
      'app_version': appVersion,
      'platform': 'web',
    },
  );
}
