import 'package:dio/dio.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';

/// Wires Dio's transport to the native HTTP stack on platforms where it's
/// available (URLSession on iOS/macOS, Cronet on Android). On Windows/Linux
/// `native_dio_adapter` itself falls back to the default Dart `HttpClient`.
void applyNativeAdapter(Dio dio) {
  dio.httpClientAdapter = NativeAdapter();
}
