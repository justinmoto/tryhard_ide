/// Result of an [autoFix] run.
class AutoFixOutcome<R> {
  const AutoFixOutcome({
    required this.attempts,
    required this.fixed,
    required this.restoredBest,
    required this.code,
    required this.report,
    this.cancelled = false,
  });

  final int attempts;
  final bool fixed;

  /// A later attempt scored worse, so the best earlier version was put back.
  final bool restoredBest;

  /// The version left in place, and its check report.
  final String code;
  final R report;
  final bool cancelled;

  String get note {
    if (fixed) return 'Auto-fixed after $attempts attempt${attempts == 1 ? '' : 's'}.';
    if (attempts == 0) return 'Auto-fix: the model returned no changes.';
    return 'Auto-fix tried $attempts time${attempts == 1 ? '' : 's'}, still failing.'
        '${restoredBest ? ' Kept the best attempt.' : ''}';
  }
}

/// Repair → re-check loop. Stops when the check passes, can no longer run,
/// the model gives nothing new, or after [maxAttempts]. Never leaves a
/// version that scores worse than the best one seen.
Future<AutoFixOutcome<R>> autoFix<R>({
  required int maxAttempts,
  required String code,
  required R report,
  required bool Function(R report) passing,
  required bool Function(R report) fixable,
  required int Function(R report) score,

  /// New code for [code] given its failing [report]; null = nothing usable.
  required Future<String?> Function(String code, R report) repair,

  /// Writes [code] to disk.
  required Future<void> Function(String code) write,

  /// Checks what is on disk.
  required Future<R> Function() check,
  bool Function()? isCancelled,
  void Function(int attempt)? onAttempt,
}) async {
  var best = (code: code, report: report);
  var current = best;
  var attempts = 0;

  while (attempts < maxAttempts && fixable(current.report)) {
    if (isCancelled?.call() ?? false) break;
    onAttempt?.call(attempts + 1);
    final next = await repair(current.code, current.report);
    if (isCancelled?.call() ?? false) break;
    if (next == null || next.trim().isEmpty || next == current.code) break;
    attempts++;
    await write(next);
    current = (code: next, report: await check());
    if (passing(current.report)) {
      return AutoFixOutcome(
        attempts: attempts,
        fixed: true,
        restoredBest: false,
        code: current.code,
        report: current.report,
      );
    }
    if (score(current.report) > score(best.report)) best = current;
  }

  final cancelled = isCancelled?.call() ?? false;
  if (!cancelled &&
      fixable(current.report) &&
      score(current.report) < score(best.report)) {
    await write(best.code);
    return AutoFixOutcome(
      attempts: attempts,
      fixed: false,
      restoredBest: true,
      code: best.code,
      report: best.report,
    );
  }
  return AutoFixOutcome(
    attempts: attempts,
    fixed: false,
    restoredBest: false,
    code: current.code,
    report: current.report,
    cancelled: cancelled,
  );
}
