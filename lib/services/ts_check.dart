import 'dart:io';

import 'package:path/path.dart' as p;

import 'shell_exec.dart';

class TscDiagnostic {
  const TscDiagnostic({
    required this.file,
    required this.line,
    required this.column,
    required this.code,
    required this.message,
  });

  final String file;
  final int line;
  final int column;
  final String code;
  final String message;

  @override
  String toString() => '${p.basename(file)}:$line:$column $code $message';
}

class TscReport {
  const TscReport({
    this.diagnostics = const [],
    this.otherFileErrors = 0,
    this.tool,
    this.error,
  });

  /// Errors in the checked file itself.
  final List<TscDiagnostic> diagnostics;

  /// Errors tsc reported in imported files (not the translation's fault).
  final int otherFileErrors;
  final String? tool;
  final String? error;

  bool get clean => error == null && diagnostics.isEmpty;

  String feedback() => diagnostics
      .take(20)
      .map((d) => '- line ${d.line}: ${d.code} ${d.message}')
      .join('\n');
}

/// `tsc --noEmit` on a single file. Passing the file directly makes tsc
/// ignore tsconfig.json, so results don't depend on project settings.
class TsCheck {
  static const _flags = [
    '--noEmit',
    '--pretty',
    'false',
    '--skipLibCheck',
    '--allowJs',
    '--esModuleInterop',
    '--resolveJsonModule',
    '--jsx',
    'react-jsx',
    '--target',
    'es2020',
    '--module',
    'esnext',
  ];

  /// `bundler` needs TS 5+, `node` was removed in TS 6; try in that order.
  static const _resolutions = ['bundler', 'node'];

  static Future<TscReport> run(String filePath, {String? rootPath}) async {
    final dir = p.dirname(filePath);
    final name = p.basename(filePath);

    final local = _findLocalTsc(dir, rootPath);
    final global = local == null ? await _findGlobalTsc() : null;
    final tool = local != null
        ? 'tsc (project)'
        : (global != null ? 'tsc (global)' : 'npx typescript@5');

    Future<ExecResult> tsc(String resolution) {
      final args = [..._flags, '--moduleResolution', resolution, name];
      final script = local ?? global;
      if (script != null) {
        return ShellExec.run('node', [script, ...args],
            workingDirectory: dir, timeout: const Duration(seconds: 90));
      }
      return ShellExec.run(
        'npx',
        ['--yes', '-p', 'typescript@5', 'tsc', ...args],
        workingDirectory: dir,
        timeout: const Duration(minutes: 3),
      );
    }

    var r = await tsc(_resolutions.first);
    // TS5023 unknown option, TS6046 bad value, TS5108 removed value.
    if (RegExp(r'error TS(5023|6046|5108)\b').hasMatch('${r.stdout}${r.stderr}')) {
      r = await tsc(_resolutions.last);
    }

    if (identical(r, ExecResult.notFound)) {
      return const TscReport(error: 'Node.js not found on PATH.');
    }
    if (r.timedOut) return TscReport(tool: tool, error: 'tsc timed out.');

    final parsed = parse('${r.stdout}\n${r.stderr}', name);
    if (r.exitCode != 0 &&
        parsed.diagnostics.isEmpty &&
        parsed.otherFileErrors == 0) {
      final lines = '${r.stderr}${r.stdout}'.split('\n').where((l) =>
          l.trim().isNotEmpty && !l.startsWith('npm notice') && !l.startsWith('npm warn'));
      return TscReport(
        tool: tool,
        error: lines.isEmpty ? 'tsc exited with ${r.exitCode}' : lines.take(4).join('\n'),
      );
    }
    return TscReport(
      tool: tool,
      diagnostics: parsed.diagnostics,
      otherFileErrors: parsed.otherFileErrors,
    );
  }

  static final _diagRe = RegExp(r'^(.+?)\((\d+),(\d+)\): error (TS\d+): (.*)$');

  static ({List<TscDiagnostic> diagnostics, int otherFileErrors}) parse(
    String output,
    String fileName,
  ) {
    final mine = <TscDiagnostic>[];
    var other = 0;
    for (final raw in output.split('\n')) {
      final m = _diagRe.firstMatch(raw.trimRight());
      if (m == null) continue;
      final file = m.group(1)!;
      if (p.basename(file) != fileName) {
        other++;
        continue;
      }
      mine.add(TscDiagnostic(
        file: file,
        line: int.parse(m.group(2)!),
        column: int.parse(m.group(3)!),
        code: m.group(4)!,
        message: m.group(5)!,
      ));
    }
    return (diagnostics: mine, otherFileErrors: other);
  }

  static String? _findLocalTsc(String dir, String? rootPath) {
    var current = p.normalize(dir);
    for (var i = 0; i < 8; i++) {
      final candidate = p.join(current, 'node_modules', 'typescript', 'lib', 'tsc.js');
      if (File(candidate).existsSync()) return candidate;
      if (rootPath != null && p.equals(current, rootPath)) break;
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }

  static String? _globalTsc;
  static bool _globalProbed = false;

  static Future<String?> _findGlobalTsc() async {
    if (_globalProbed) return _globalTsc;
    _globalProbed = true;
    final r = await ShellExec.run('npm', const ['root', '-g'],
        timeout: const Duration(seconds: 15));
    if (!r.ok) return null;
    final candidate = p.join(r.stdout.trim(), 'typescript', 'lib', 'tsc.js');
    if (File(candidate).existsSync()) _globalTsc = candidate;
    return _globalTsc;
  }
}
