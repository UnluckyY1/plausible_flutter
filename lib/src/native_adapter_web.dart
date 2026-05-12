import 'package:dio/dio.dart';

/// Web stub — `native_dio_adapter` transitively imports `dart:ffi`, so we
/// can't reference it at all in code that targets the browser. Dio's default
/// adapter on web is `BrowserHttpClientAdapter` (XHR), which is what we want.
void applyNativeAdapter(Dio dio) {
  // Intentionally no-op.
}
