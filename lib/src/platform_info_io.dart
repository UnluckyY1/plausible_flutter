import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'platform_info.dart';

Future<PlausiblePlatformInfo> detectPlatformInfo({
  bool includeDeviceModel = true,
}) async {
  final pkg = await PackageInfo.fromPlatform();
  final appName = PlausiblePlatformInfo.sanitize(
      pkg.appName.isEmpty ? 'FlutterApp' : pkg.appName);
  final appVersion = pkg.version.isEmpty ? '0.0.0' : pkg.version;
  final info = DeviceInfoPlugin();

  if (Platform.isIOS) {
    final ios = await info.iosInfo;
    final osVersion = ios.systemVersion;
    final device = ios.utsname.machine;
    return PlausiblePlatformInfo(
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS ${osVersion.replaceAll('.', '_')} like Mac OS X) $appName/$appVersion',
      defaultProps: {
        'app_version': appVersion,
        'platform': 'ios',
        'os_version': osVersion,
        if (includeDeviceModel) 'device_model': device,
      },
    );
  }

  if (Platform.isAndroid) {
    final android = await info.androidInfo;
    final osVersion = android.version.release;
    final device = android.model;
    return PlausiblePlatformInfo(
      userAgent: PlausiblePlatformInfo.buildAndroidUserAgent(
        appName: appName,
        appVersion: appVersion,
        osVersion: osVersion,
        device: includeDeviceModel ? device : null,
      ),
      defaultProps: {
        'app_version': appVersion,
        'platform': 'android',
        'os_version': osVersion,
        if (includeDeviceModel) 'device_model': device,
      },
    );
  }

  if (Platform.isMacOS) {
    final mac = await info.macOsInfo;
    final osVersion = '${mac.majorVersion}.${mac.minorVersion}';
    return PlausiblePlatformInfo(
      userAgent:
          'Mozilla/5.0 (Macintosh; Intel Mac OS X ${osVersion.replaceAll('.', '_')}) $appName/$appVersion',
      defaultProps: {
        'app_version': appVersion,
        'platform': 'macos',
        'os_version': osVersion,
        if (includeDeviceModel) 'device_model': mac.model,
      },
    );
  }

  if (Platform.isWindows) {
    final win = await info.windowsInfo;
    final osVersion = '${win.majorVersion}.${win.minorVersion}';
    return PlausiblePlatformInfo(
      userAgent: 'Mozilla/5.0 (Windows NT $osVersion) $appName/$appVersion',
      defaultProps: {
        'app_version': appVersion,
        'platform': 'windows',
        'os_version': osVersion,
      },
    );
  }

  if (Platform.isLinux) {
    final linux = await info.linuxInfo;
    final osVersion = linux.version ?? linux.versionId ?? 'unknown';
    return PlausiblePlatformInfo(
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) $appName/$appVersion',
      defaultProps: {
        'app_version': appVersion,
        'platform': 'linux',
        'os_version': osVersion,
      },
    );
  }

  return PlausiblePlatformInfo(
    userAgent: '$appName/$appVersion',
    defaultProps: {
      'app_version': appVersion,
      'platform': 'unknown',
    },
  );
}
