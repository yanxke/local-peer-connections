import '../types.dart';

/// Deterministic Section 25 reconnect-attempt timing. The owning runtime
/// provides a monotonic clock, performs physical connection attempts when
/// [attemptDue] is true, and calls [attemptFailed] only after an attempt has
/// actually failed. This class has no transport or timer dependency.
class ReconnectSchedule {
  ReconnectSchedule({required this.startedAtMs, required this.timeoutMs}) {
    if (timeoutMs < 1000 || timeoutMs > 60000) {
      throw ArgumentError.value(timeoutMs, 'timeoutMs');
    }
    _nextAttemptAtMs = startedAtMs;
  }

  final int startedAtMs, timeoutMs;
  late int _nextAttemptAtMs;
  int _failedAttempts = 0;
  bool _cancelled = false;

  int get failedAttempts => _failedAttempts;
  int get nextAttemptAtMs => _nextAttemptAtMs;
  bool get cancelled => _cancelled;

  bool expiredAt(int nowMs) => nowMs - startedAtMs >= timeoutMs;

  bool attemptDue(int nowMs) =>
      !_cancelled && !expiredAt(nowMs) && nowMs >= _nextAttemptAtMs;

  /// Records a failed physical attempt and schedules the next one: 250 ms,
  /// 500 ms, 1000 ms, then 2000 ms for every subsequent failure.
  void attemptFailed(int nowMs) {
    if (!attemptDue(nowMs)) {
      throw const LpcException(
          LpcErrorCode.invalidState, 'reconnect attempt is not due');
    }
    _failedAttempts++;
    _nextAttemptAtMs = nowMs + _delayAfterFailure(_failedAttempts);
  }

  void cancel() => _cancelled = true;

  int _delayAfterFailure(int failure) => switch (failure) {
        1 => 250,
        2 => 500,
        3 => 1000,
        _ => 2000,
      };
}
