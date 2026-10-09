import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'run_service.dart';

class ExecResult {
  const ExecResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;

  bool get ok => exitCode == 0 && !timedOut;

  static const notFound = ExecResult(exitCode: -1, stdout: '', stderr: '');
}

/// One-shot process runner for the translator checks (node, python, tsc).
///
/// On Windows executables are started directly (`.cmd` shims via the shell);
/// elsewhere commands go through a login zsh so Homebrew/nvm installs resolve,
/// matching [RunService].
class ShellExec {
  static Future<ExecResult> run(
    String exe,
    List<String> args, {
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final Process process;
    try {
      if (Platform.isWindows) {
        process = await Process.start(
          exe,
          args,
          workingDirectory: workingDirectory,
          environment: RunService.enrichedEnv(),
          runInShell: exe.endsWith('.cmd') || exe == 'npx' || exe == 'npm',
        );
      } else {
        final command = [exe, ...args].map(_shQuote).join(' ');
        process = await Process.start(
          '/bin/zsh',
          ['-lc', command],
          workingDirectory: workingDirectory,
          environment: RunService.enrichedEnv(),
        );
      }
    } on ProcessException {
      return ExecResult.notFound;
    }

    final out = process.stdout.transform(utf8.decoder).join();
    final err = process.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    return ExecResult(
      exitCode: code,
      stdout: await out.timeout(const Duration(seconds: 2), onTimeout: () => ''),
      stderr: await err.timeout(const Duration(seconds: 2), onTimeout: () => ''),
      timedOut: timedOut,
    );
  }

  static String _shQuote(String s) {
    if (RegExp(r'^[\w@%+=:,./-]+$').hasMatch(s)) return s;
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  static ({String exe, List<String> prefix})? _python;
  static bool _pythonProbed = false;

  /// First working Python 3 among `python3`, `python`, `py -3`. Rejects the
  /// Windows Store alias stub, which exists on PATH but only prints a hint.
  static Future<({String exe, List<String> prefix})?> python() async {
    if (_pythonProbed) return _python;
    for (final candidate in [
      (exe: 'python3', prefix: const <String>[]),
      (exe: 'python', prefix: const <String>[]),
      (exe: 'py', prefix: const <String>['-3']),
    ]) {
      final r = await run(
        candidate.exe,
        [...candidate.prefix, '--version'],
        timeout: const Duration(seconds: 8),
      );
      if (r.ok && '${r.stdout}${r.stderr}'.contains('Python 3')) {
        _python = candidate;
        break;
      }
    }
    _pythonProbed = true;
    return _python;
  }

  static Future<bool> hasNode() async {
    final r = await run('node', const ['--version'],
        timeout: const Duration(seconds: 8));
    return r.ok;
  }
}
