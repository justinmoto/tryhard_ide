import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tryhard_ide/services/code_translator.dart';
import 'package:tryhard_ide/services/equivalence_check.dart';
import 'package:tryhard_ide/services/ollama_service.dart';
import 'package:tryhard_ide/services/shell_exec.dart';
import 'package:tryhard_ide/services/ts_check.dart';

void main() {
  group('TranslationKind', () {
    test('offers conversions by extension', () {
      expect(TranslationKind.forPath('a/b.js'), [TranslationKind.jsToTs, TranslationKind.jsToPython]);
      expect(TranslationKind.forPath('a/b.jsx'), [TranslationKind.jsToTs]);
      expect(TranslationKind.forPath('a/b.py'), [TranslationKind.pythonToJs]);
      expect(TranslationKind.forPath('a/b.dart'), isEmpty);
      expect(TranslationKind.forPath(null), isEmpty);
    });

    test('target paths', () {
      expect(TranslationKind.jsToTs.targetPath(p.join('src', 'App.jsx')), p.join('src', 'App.tsx'));
      expect(TranslationKind.jsToTs.targetPath(p.join('src', 'util.js')), p.join('src', 'util.ts'));
      expect(TranslationKind.jsToPython.targetPath(p.join('src', 'my-utils.js')), p.join('src', 'my_utils.py'));
      expect(TranslationKind.pythonToJs.targetPath(p.join('lib', 'calc.py')), p.join('lib', 'calc.js'));
    });
  });

  test('extractCode takes the largest fence, tolerates unterminated ones', () {
    expect(
      CodeTranslator.extractCode('Here:\n```py\nx = 1\n```\nand\n```python\ndef f():\n    return 2\n```'),
      'def f():\n    return 2\n',
    );
    expect(CodeTranslator.extractCode('```ts\nconst a = 1;\n'), 'const a = 1;\n');
    expect(CodeTranslator.extractCode('const a = 1;'), 'const a = 1;\n');
  });

  group('EquivalenceCheck parsing', () {
    test('extracts top-level JS functions only', () {
      const js = '''
export function addTwo(a, b) { return a + b; }
const square = (x) => x * x;
export const asyncThing = async (x) => x;
let half = x => x / 2;
function main() {}
class Foo { method() {} }
  function nested() {}
''';
      expect(EquivalenceCheck.extractJsFunctions(js), ['addTwo', 'square', 'asyncThing', 'half']);
    });

    test('extracts top-level Python defs', () {
      const py = 'def add_two(a, b):\n    def inner():\n        pass\n    return a + b\n\nasync def fetch(x):\n    pass\n\ndef __repr__(self):\n    pass\n';
      expect(EquivalenceCheck.extractPyFunctions(py), ['add_two', 'fetch']);
    });

    test('parses lenient case JSON and drops unknown functions', () {
      const reply = 'Sure!\n```json\n[{"fn": "add", "args": [1, 2]}, {"fn": "nope", "args": []}, '
          '{"function": "add", "arguments": [0, -1]}, {"fn": "add", "args": [1, 2]}]\n```';
      final cases = EquivalenceCheck.parseCases(reply, ['add']);
      expect(cases.map((c) => c.call), ['add(1, 2)', 'add(0, -1)']);
      expect(EquivalenceCheck.parseCases('no json here', ['add']), isEmpty);
    });

    test('name style conversion', () {
      expect(EquivalenceCheck.snakeCase('parseHTTPHeader'), 'parse_http_header');
      expect(EquivalenceCheck.snakeCase('addTwo'), 'add_two');
      expect(EquivalenceCheck.camelCase('add_two_numbers'), 'addTwoNumbers');
    });

    test('valuesEqual across languages', () {
      expect(EquivalenceCheck.valuesEqual(1, 1.0), isTrue);
      expect(EquivalenceCheck.valuesEqual(0.1 + 0.2, 0.3), isTrue);
      expect(EquivalenceCheck.valuesEqual({'a': 1, 'b': [1, 2]}, {'b': [1, 2.0], 'a': 1}), isTrue);
      expect(EquivalenceCheck.valuesEqual([1, 2], [2, 1]), isFalse);
      expect(EquivalenceCheck.valuesEqual(null, 0), isFalse);
      expect(EquivalenceCheck.valuesEqual('1', 1), isFalse);
    });

    test('detects ES modules', () {
      expect(EquivalenceCheck.isEsm('export function a() {}'), isTrue);
      expect(EquivalenceCheck.isEsm("import fs from 'fs';"), isTrue);
      expect(EquivalenceCheck.isEsm('module.exports = { a };'), isFalse);
    });
  });

  group('EquivalenceCheck runs node and python', () {
    late Directory dir;
    ({String exe, List<String> prefix})? python;
    var node = false;

    setUpAll(() async {
      python = await ShellExec.python();
      node = await ShellExec.hasNode();
    });
    setUp(() => dir = Directory.systemTemp.createTempSync('tryhard_equiv'));
    tearDown(() => dir.deleteSync(recursive: true));

    const js = '''
function addTwo(a, b) { return a + b; }
function clamp(x, lo, hi) { return Math.min(Math.max(x, lo), hi); }
function divide(a, b) { if (b === 0) throw new Error('div by zero'); return a / b; }
function stats(xs) { return { count: xs.length, max: xs.length ? Math.max(...xs) : null }; }
module.exports = { addTwo };
''';
    final cases = [
      const TestCase('addTwo', [1, 2]),
      const TestCase('clamp', [15, 0, 10]),
      const TestCase('divide', [1, 0]),
      const TestCase('divide', [7, 2]),
      const TestCase('stats', [[3, 9, 4]]),
      const TestCase('stats', [<int>[]]),
    ];

    Future<EquivalenceReport> check(String py) {
      final source = p.join(dir.path, 'math.js');
      File(source).writeAsStringSync(js);
      return EquivalenceCheck(OllamaService()).runCases(
        sourceLang: Lang.js,
        sourceCode: js,
        targetCode: py,
        sourcePath: source,
        cases: cases,
        python: python!,
      );
    }

    test('faithful translation matches every case', () async {
      if (python == null || !node) return markTestSkipped('needs node + python');
      final report = await check('''
def add_two(a, b):
    return a + b

def clamp(x, lo, hi):
    return min(max(x, lo), hi)

def divide(a, b):
    if b == 0:
        raise ZeroDivisionError("div by zero")
    return a / b

def stats(xs):
    return {"count": len(xs), "max": max(xs) if xs else None}

if __name__ == "__main__":
    print("main block must not run")
''');
      expect(report.error, isNull);
      expect(report.matched, 6, reason: report.feedback());
      expect(report.allMatch, isTrue);
    });

    test('buggy translation is caught with useful feedback', () async {
      if (python == null || !node) return markTestSkipped('needs node + python');
      final report = await check('''
def add_two(a, b):
    return a + b

def clamp(x, lo, hi):
    return max(x, lo)

def divide(a, b):
    return a // b if b else 0

def stats(xs):
    return {"count": len(xs), "max": max(xs) if xs else None}
''');
      expect(report.error, isNull);
      expect(report.total, 6);
      expect(report.matched, 3);
      final feedback = report.feedback();
      expect(feedback, contains('clamp(15, 0, 10): expected 10, got 15'));
      expect(feedback, contains('divide(1, 0): expected throws'));
      expect(feedback, contains('divide(7, 2): expected 3.5, got 3'));
      expect(dir.listSync().map((e) => p.basename(e.path)), ['math.js'], reason: 'temp files cleaned up');
    });

    test('python → ES module JS, non-exported helpers and async', () async {
      if (python == null || !node) return markTestSkipped('needs node + python');
      const py = 'def word_count(text):\n    return len(text.split())\n\n'
          'def title_case(s):\n    return " ".join(w.capitalize() for w in s.split())\n';
      const mjs = "import { EOL } from 'node:os';\n"
          'export function wordCount(text) { return text.split(/\\s+/).filter(Boolean).length; }\n'
          'async function titleCase(s) { return s.split(/\\s+/).filter(Boolean)'
          '.map((w) => w[0].toUpperCase() + w.slice(1).toLowerCase()).join(" "); }\n';
      final source = p.join(dir.path, 'text.py');
      File(source).writeAsStringSync(py);
      final report = await EquivalenceCheck(OllamaService()).runCases(
        sourceLang: Lang.python,
        sourceCode: py,
        targetCode: mjs,
        sourcePath: source,
        cases: const [
          TestCase('word_count', ['  hello big   world ']),
          TestCase('title_case', ['hELLO wORLD']),
        ],
        python: python!,
      );
      expect(report.error, isNull);
      expect(report.allMatch, isTrue, reason: report.feedback());
    });

    test('missing function is a mismatch, not "both throw"', () async {
      if (python == null || !node) return markTestSkipped('needs node + python');
      final report = await check('def add_two(a, b):\n    return a + b\n');
      expect(report.cases.where((c) => c.testCase.fn == 'divide' && c.testCase.args[1] == 0).single.matches, isFalse);
    });
  });

  group('TsCheck', () {
    test('parses diagnostics and separates other files', () {
      const out = 'util.ts(3,7): error TS2322: Type \'string\' is not assignable to type \'number\'.\n'
          'node_modules/x/index.d.ts(1,1): error TS1005: \';\' expected.\n'
          'random noise\n';
      final r = TsCheck.parse(out, 'util.ts');
      expect(r.diagnostics.single.line, 3);
      expect(r.diagnostics.single.code, 'TS2322');
      expect(r.otherFileErrors, 1);
    });
  });
}
