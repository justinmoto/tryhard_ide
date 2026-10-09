import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ollama_service.dart';
import 'shell_exec.dart';

enum Lang { js, python }

class TestCase {
  const TestCase(this.fn, this.args);

  final String fn;
  final List<dynamic> args;

  String get call {
    final a = args.map(jsonEncode).join(', ');
    return '$fn($a)';
  }
}

/// One side's outcome for a case: a JSON value or an error message.
class RunOutcome {
  const RunOutcome.value(this.value) : error = null;
  const RunOutcome.error(this.error) : value = null;

  final Object? value;
  final String? error;

  bool get ok => error == null;

  @override
  String toString() => ok ? jsonEncode(value) : 'throws: $error';
}

class CaseResult {
  const CaseResult({
    required this.testCase,
    required this.source,
    required this.target,
  });

  final TestCase testCase;
  final RunOutcome source;
  final RunOutcome target;

  /// Same value, or both sides raise (error text differs across languages).
  bool get matches => source.ok
      ? target.ok && EquivalenceCheck.valuesEqual(source.value, target.value)
      : !target.ok && !_missing(source) && !_missing(target);

  static bool _missing(RunOutcome o) =>
      o.error!.startsWith(EquivalenceCheck.notFoundPrefix);
}

class EquivalenceReport {
  const EquivalenceReport({this.cases = const [], this.error});

  final List<CaseResult> cases;

  /// Set when the check could not run at all (no node/python, bad output…).
  final String? error;

  int get total => cases.length;
  int get matched => cases.where((c) => c.matches).length;
  bool get allMatch => error == null && total > 0 && matched == total;

  /// Mismatches in a form the model can act on.
  String feedback() {
    final lines = <String>[];
    for (final c in cases.where((c) => !c.matches)) {
      lines.add('- ${c.testCase.call}: expected ${c.source}, got ${c.target}');
    }
    return lines.join('\n');
  }
}

/// Runs the original and translated file on the same inputs and compares.
class EquivalenceCheck {
  EquivalenceCheck(this.ollama);

  final OllamaService ollama;

  static const notFoundPrefix = 'function not found';
  static const _marker = '__TRYHARD_RESULT__';
  static const _maxFunctions = 8;

  Future<EquivalenceReport> run({
    required Lang sourceLang,
    required String sourceCode,
    required String targetCode,
    required String sourcePath,
    String? model,
    void Function(String status)? onStatus,

    /// Reuse earlier inputs so attempts are graded on the same test.
    List<TestCase>? cases,
  }) async {
    final fns = sourceLang == Lang.js
        ? extractJsFunctions(sourceCode)
        : extractPyFunctions(sourceCode);
    if (fns.isEmpty) {
      return const EquivalenceReport(
        error: 'No top-level functions to test.',
      );
    }

    onStatus?.call('Checking node & python…');
    final python = await ShellExec.python();
    if (python == null) {
      return const EquivalenceReport(error: 'Python 3 not found on PATH.');
    }
    if (!await ShellExec.hasNode()) {
      return const EquivalenceReport(error: 'Node.js not found on PATH.');
    }

    if (cases == null || cases.isEmpty) {
      onStatus?.call('Generating test inputs…');
      try {
        final reply = await ollama.chat(
          messages: casePrompt(sourceCode, fns, sourceLang),
          model: model,
        );
        cases = parseCases(reply, fns);
      } on ChatCancelledException {
        rethrow;
      } catch (e) {
        return EquivalenceReport(error: 'Test input generation failed: $e');
      }
    }
    if (cases.isEmpty) {
      return const EquivalenceReport(
        error: 'Model returned no usable test inputs. Try again.',
      );
    }

    onStatus?.call('Running ${cases.length} cases in both languages…');
    return runCases(
      sourceLang: sourceLang,
      sourceCode: sourceCode,
      targetCode: targetCode,
      sourcePath: sourcePath,
      cases: cases,
      python: python,
    );
  }

  /// Runs [cases] against both files and compares (no model involved).
  Future<EquivalenceReport> runCases({
    required Lang sourceLang,
    required String sourceCode,
    required String targetCode,
    required String sourcePath,
    required List<TestCase> cases,
    required ({String exe, List<String> prefix}) python,
  }) async {
    final dir = p.dirname(sourcePath);
    final jsCode = sourceLang == Lang.js ? sourceCode : targetCode;
    final pyCode = sourceLang == Lang.js ? targetCode : sourceCode;
    final jsNames = [for (final c in cases) _candidates(c.fn, Lang.js)];
    final pyNames = [for (final c in cases) _candidates(c.fn, Lang.python)];

    final results = await Future.wait([
      _runJs(dir, jsCode, cases, jsNames),
      _runPython(dir, pyCode, cases, pyNames, python),
    ]);
    final js = results[0];
    final py = results[1];
    if (js is String) return EquivalenceReport(error: 'JavaScript: $js');
    if (py is String) return EquivalenceReport(error: 'Python: $py');
    final jsOut = js as List<RunOutcome>;
    final pyOut = py as List<RunOutcome>;

    return EquivalenceReport(
      cases: [
        for (var i = 0; i < cases.length; i++)
          CaseResult(
            testCase: cases[i],
            source: sourceLang == Lang.js ? jsOut[i] : pyOut[i],
            target: sourceLang == Lang.js ? pyOut[i] : jsOut[i],
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- parsing

  static final _ident = RegExp(r'^[A-Za-z_$][\w$]*$');

  /// Top-level (unindented) function declarations and arrow/function consts.
  static List<String> extractJsFunctions(String code) {
    final out = <String>[];
    final patterns = [
      RegExp(
        r'^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(',
        multiLine: true,
      ),
      RegExp(
        r'^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)',
        multiLine: true,
      ),
    ];
    final found = <({int at, String name})>[];
    for (final re in patterns) {
      for (final m in re.allMatches(code)) {
        found.add((at: m.start, name: m.group(1)!));
      }
    }
    found.sort((a, b) => a.at.compareTo(b.at));
    for (final f in found) {
      if (f.name == 'main' || out.contains(f.name)) continue;
      out.add(f.name);
    }
    return out.take(_maxFunctions).toList();
  }

  static List<String> extractPyFunctions(String code) {
    final out = <String>[];
    final re = RegExp(r'^(?:async\s+)?def\s+([A-Za-z_]\w*)\s*\(', multiLine: true);
    for (final m in re.allMatches(code)) {
      final name = m.group(1)!;
      if (name == 'main' || name.startsWith('__') || out.contains(name)) {
        continue;
      }
      out.add(name);
    }
    return out.take(_maxFunctions).toList();
  }

  static List<ChatMessage> casePrompt(String code, List<String> fns, Lang lang) {
    final language = lang == Lang.js ? 'JavaScript' : 'Python';
    return [
      const ChatMessage(
        role: 'system',
        content: 'You write test inputs. Reply with ONLY a JSON array, no prose. '
            'Each item: {"fn": "<function name>", "args": [<positional arguments>]}. '
            'Arguments must be plain JSON (numbers, strings, booleans, null, arrays, objects). '
            'Give 3 cases per function: a typical input, an edge case (empty, zero, negative), and one more.',
      ),
      ChatMessage(
        role: 'user',
        content: 'Functions: ${fns.join(', ')}\n\n$language source:\n```\n$code\n```',
      ),
    ];
  }

  /// Lenient parse of the model's JSON array; drops unknown functions.
  static List<TestCase> parseCases(String reply, List<String> fns) {
    final start = reply.indexOf('[');
    final end = reply.lastIndexOf(']');
    if (start < 0 || end <= start) return const [];
    Object? data;
    try {
      data = jsonDecode(reply.substring(start, end + 1));
    } catch (_) {
      return const [];
    }
    if (data is! List) return const [];
    final out = <TestCase>[];
    final seen = <String>{};
    for (final item in data) {
      if (item is! Map) continue;
      final fn = item['fn'] ?? item['function'] ?? item['name'];
      final args = item['args'] ?? item['arguments'] ?? const [];
      if (fn is! String || !fns.contains(fn) || args is! List) continue;
      if (!seen.add('$fn${jsonEncode(args)}')) continue;
      out.add(TestCase(fn, args));
      if (out.length >= 24) break;
    }
    return out;
  }

  /// Names to try for [fn] in [lang]: as-is, then the other naming style.
  static List<String> _candidates(String fn, Lang lang) {
    final alt = lang == Lang.python ? snakeCase(fn) : camelCase(fn);
    return [fn, if (alt != fn) alt].where(_ident.hasMatch).toList();
  }

  static String snakeCase(String s) => s
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase();

  static String camelCase(String s) => s.replaceAllMapped(
        RegExp(r'_+([a-z0-9])'),
        (m) => m[1]!.toUpperCase(),
      );

  /// Deep equality across languages: 1 == 1.0, map key order ignored,
  /// floats compared with a relative tolerance.
  static bool valuesEqual(Object? a, Object? b) {
    if (a is num && b is num) {
      if (a == b) return true;
      final scale = [1.0, a.abs().toDouble(), b.abs().toDouble()]
          .reduce((x, y) => x > y ? x : y);
      return (a - b).abs() <= 1e-9 * scale;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!valuesEqual(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !valuesEqual(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }

  // ---------------------------------------------------------------- runners

  static bool isEsm(String code) => RegExp(
        r'''^\s*(?:import\s+[\w{*'"]|export\s)''',
        multiLine: true,
      ).hasMatch(code);

  /// Harness appended to the JS source so non-exported functions are
  /// reachable by name (direct eval sees the module scope).
  static String jsHarness(List<List<String>> names, List<TestCase> cases) {
    final payload = jsonEncode([
      for (var i = 0; i < cases.length; i++)
        {'names': names[i], 'args': cases[i].args},
    ]);
    return '''

;(async () => {
  const norm = (v) => {
    if (v === undefined) return null;
    if (typeof v === 'number' && !Number.isFinite(v)) return String(v);
    if (typeof v === 'bigint') return Number(v);
    if (v instanceof Map) return norm(Object.fromEntries(v));
    if (v instanceof Set) return [...v].map(norm);
    if (Array.isArray(v)) return v.map(norm);
    if (v && typeof v === 'object') {
      const o = {};
      for (const k of Object.keys(v)) o[k] = norm(v[k]);
      return o;
    }
    return v;
  };
  const out = [];
  for (const c of $payload) {
    let fn;
    for (const n of c.names) {
      try { fn = eval(n); } catch (_) { fn = undefined; }
      if (typeof fn === 'function') break;
      fn = undefined;
    }
    if (!fn) { out.push({ ok: false, error: '$notFoundPrefix: ' + c.names[0] }); continue; }
    try {
      let v = fn(...c.args);
      if (v && typeof v.then === 'function') v = await v;
      out.push({ ok: true, value: norm(v) });
    } catch (e) {
      out.push({ ok: false, error: String((e && e.message) || e) });
    }
  }
  process.stdout.write('\\n$_marker' + JSON.stringify(out) + '\\n');
  process.exit(0);
})();
''';
  }

  static const pyHarness = '''
import asyncio, importlib.util, inspect, json, math, os, sys

mod_path, cases_path = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(os.path.abspath(mod_path)))
spec = importlib.util.spec_from_file_location("_tryhard_mod", mod_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def norm(v):
    if v is None or isinstance(v, (bool, str, int)):
        return v
    if isinstance(v, float):
        if math.isnan(v): return "NaN"
        if math.isinf(v): return "Infinity" if v > 0 else "-Infinity"
        return v
    if isinstance(v, dict):
        return {str(k): norm(x) for k, x in v.items()}
    if isinstance(v, (list, tuple, set, frozenset)):
        return [norm(x) for x in v]
    return repr(v)

async def _await(v):
    return await v

with open(cases_path, encoding="utf-8") as f:
    cases = json.load(f)
out = []
for c in cases:
    fn = None
    for n in c["names"]:
        fn = getattr(mod, n, None)
        if callable(fn):
            break
        fn = None
    if fn is None:
        out.append({"ok": False, "error": "$notFoundPrefix: " + c["names"][0]})
        continue
    try:
        v = fn(*c["args"])
        if inspect.isawaitable(v):
            v = asyncio.run(_await(v))
        out.append({"ok": True, "value": norm(v)})
    except Exception as e:
        out.append({"ok": False, "error": str(e) or type(e).__name__})
sys.stdout.write("\\n$_marker" + json.dumps(out) + "\\n")
''';

  /// Temp files go next to the source so relative imports still resolve;
  /// they are dot-prefixed and always removed.
  Future<Object> _runJs(
    String dir,
    String code,
    List<TestCase> cases,
    List<List<String>> names,
  ) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final ext = isEsm(code) ? '.mjs' : '.cjs';
    final file = File(p.join(dir, '.tryhard-check-$stamp$ext'));
    try {
      await file.writeAsString(code + jsHarness(names, cases), flush: true);
      final r = await ShellExec.run(
        'node',
        [p.basename(file.path)],
        workingDirectory: dir,
        timeout: const Duration(seconds: 20),
      );
      return parseRunOutput(r, cases.length);
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  Future<Object> _runPython(
    String dir,
    String code,
    List<TestCase> cases,
    List<List<String>> names,
    ({String exe, List<String> prefix}) python,
  ) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final mod = File(p.join(dir, '.tryhard_check_${stamp}_mod.py'));
    final harness = File(p.join(Directory.systemTemp.path, 'tryhard_harness_$stamp.py'));
    final casesFile = File(p.join(Directory.systemTemp.path, 'tryhard_cases_$stamp.json'));
    try {
      await mod.writeAsString(code, flush: true);
      await harness.writeAsString(pyHarness, flush: true);
      await casesFile.writeAsString(
        jsonEncode([
          for (var i = 0; i < cases.length; i++)
            {'names': names[i], 'args': cases[i].args},
        ]),
        flush: true,
      );
      final r = await ShellExec.run(
        python.exe,
        [...python.prefix, '-B', harness.path, p.basename(mod.path), casesFile.path],
        workingDirectory: dir,
        timeout: const Duration(seconds: 20),
      );
      return parseRunOutput(r, cases.length);
    } finally {
      for (final f in [mod, harness, casesFile]) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  /// Outcomes from the harness marker line, or an error string.
  static Object parseRunOutput(ExecResult r, int expected) {
    if (r.timedOut) return 'timed out after 20s';
    if (identical(r, ExecResult.notFound)) return 'interpreter not found';
    final line = const LineSplitter()
        .convert(r.stdout)
        .lastWhere((l) => l.startsWith(_marker), orElse: () => '');
    if (line.isEmpty) {
      final err = r.stderr.trim().split('\n').where((l) => l.trim().isNotEmpty);
      return err.isEmpty
          ? 'exited with code ${r.exitCode} and no output'
          : err.take(6).join('\n');
    }
    final data = jsonDecode(line.substring(_marker.length)) as List<dynamic>;
    if (data.length != expected) return 'harness returned ${data.length}/$expected results';
    return [
      for (final d in data.cast<Map<String, dynamic>>())
        d['ok'] == true
            ? RunOutcome.value(d['value'])
            : RunOutcome.error('${d['error']}'),
    ];
  }
}
