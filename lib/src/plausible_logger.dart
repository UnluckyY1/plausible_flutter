import 'package:logger/logger.dart';

/// Internal logger. Wraps `package:logger` so the package gets proper levels
/// and formatting, and so consumers can route plausible's output into their
/// own logging stack by passing a custom [Logger] to `Plausible.init`.
///
/// Levels in use:
///   - [debug]: per-event traces (sent / queued / drain paused / skipped).
///   - [info]: lifecycle state changes (initialized, tracking enabled/disabled,
///     queue ready/recovered).
///   - [warn]: recoverable issues (retry-later, drop-permanent, queue
///     unavailable, corrupt queue entry).
///   - [error]: unexpected exceptions that bubble out of `_client.send`.
class PlausibleLogger {
  final bool enabled;
  final Logger _logger;

  PlausibleLogger({this.enabled = false, Logger? logger})
    : _logger =
          logger ??
          Logger(
            printer: SimplePrinter(printTime: false, colors: true),
            // When the consumer doesn't inject their own Logger, gate output
            // on the package's `enabled` flag via Level.off — keeps release
            // builds silent unless the consumer explicitly wires logging.
            level: enabled ? Level.debug : Level.off,
          );

  void debug(String message) => _logger.d('[plausible] $message');

  void info(String message) => _logger.i('[plausible] $message');

  void warn(String message, [Object? error]) =>
      _logger.w('[plausible] $message', error: error);

  void error(String message, [Object? error, StackTrace? stackTrace]) =>
      _logger.e('[plausible] $message', error: error, stackTrace: stackTrace);
}
