import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class RunTarget {
  const RunTarget({
    required this.id,
    required this.label,
    required this.command,
  });

  final String id;
  final String label;
  final String command;
}

class RunService extends ChangeNotifier {
  Process? _process;
  final _lines = <String>[];
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  RunTarget? _activeTarget;
  bool _running = false;
  int? _exitCode;

  bool get isRunning => _running;
  RunTarget? get activeTarget => _activeTarget;
  int? get exitCode => _exitCode;
  List<String> get lines => List.unmodifiable(_lines);

  static Future<List<RunTarget>> detectTargets(String? rootPath) async {
    if (rootPath == null || rootPath.isEmpty || kIsWeb) return const [];

    final root = Directory(rootPath);
    if (!await root.exists()) return const [];

    final targets = <RunTarget>[];
    final packageJson = File(p.join(rootPath, 'package.json'));
    if (await packageJson.exists()) {
      try {
        final data =
            jsonDecode(await packageJson.readAsString()) as Map<String, dynamic>;
        final scripts = data['scripts'];
        if (scripts is Map) {
          for (final preferred in ['dev', 'start', 'build', 'test', 'lint']) {
            if (scripts.containsKey(preferred)) {
              targets.add(
                RunTarget(
                  id: 'npm:$preferred',
                  label: 'npm run $preferred',
                  command: 'npm run $preferred',
                ),
              );
            }
          }
          for (final key in scripts.keys) {
            final name = '$key';
            if (['dev', 'start', 'build', 'test', 'lint'].contains(name)) {
              continue;
            }
            targets.add(
              RunTarget(
                id: 'npm:$name',
                label: 'npm run $name',
                command: 'npm run $name',
              ),
            );
            if (targets.length >= 12) break;
          }
        }
      } catch (_) {
        targets.add(
          const RunTarget(
            id: 'npm:start',
            label: 'npm start',
            command: 'npm start',
          ),
        );
      }
    }

    final pubspec = File(p.join(rootPath, 'pubspec.yaml'));
    if (await pubspec.exists()) {
      final devices = await _flutterDevices();
      if (devices.isEmpty) {
        targets.add(
          const RunTarget(
            id: 'flutter:run',
            label: 'flutter run (pick device manually)',
            command: 'flutter run',
          ),
        );
      } else {
        for (final d in devices) {
          targets.add(
            RunTarget(
              id: 'flutter:run:${d.id}',
              label: 'flutter run → ${d.name} (${d.id})',
              command: 'flutter run -d ${d.id}',
            ),
          );
        }
      }
      targets.addAll(const [
        RunTarget(
          id: 'flutter:test',
          label: 'flutter test',
          command: 'flutter test',
        ),
        RunTarget(
          id: 'flutter:analyze',
          label: 'flutter analyze',
          command: 'flutter analyze',
        ),
        RunTarget(
          id: 'flutter:devices',
          label: 'flutter devices',
          command: 'flutter devices',
        ),
      ]);
    }

    final hasPytest = await File(p.join(rootPath, 'pytest.ini')).exists() ||
        await File(p.join(rootPath, 'pyproject.toml')).exists() ||
        await Directory(p.join(rootPath, 'tests')).exists();
    final hasRequirements =
        await File(p.join(rootPath, 'requirements.txt')).exists();
    if (hasPytest || hasRequirements) {
      targets.add(
        const RunTarget(
          id: 'pytest',
          label: 'pytest',
          command: 'pytest -q',
        ),
      );
    }

    if (targets.isEmpty) {
      targets.add(
        const RunTarget(
          id: 'echo',
          label: 'echo (no project scripts)',
          command: 'echo "No package.json / pubspec.yaml scripts found"',
        ),
      );
    }

    return targets;
  }

  static Future<List<({String id, String name})>> _flutterDevices() async {
    try {
      final result = await Process.run(
        '/bin/zsh',
        const ['-lc', 'flutter devices --machine'],
        environment: enrichedEnv(),
      );
      if (result.exitCode != 0) return const [];
      final raw = (result.stdout as String).trim();
      if (raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      final out = <({String id, String name})>[];
      for (final item in list) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        if (id.isEmpty) continue;
        final name = '${item['name'] ?? id}';
        out.add((id: id, name: name));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Process environment with common Node/Flutter install dirs on PATH
  /// (GUI apps on macOS don't inherit the login shell's PATH).
  static Map<String, String> enrichedEnv() {
    final env = Map<String, String>.from(Platform.environment);
    if (!Platform.isWindows) {
      final home = env['HOME'] ?? '';
      final extras = <String>[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/opt/homebrew/share/flutter/bin',
        '$home/flutter/bin',
      ];
      try {
        final nvmDir = Directory('$home/.nvm/versions/node');
        if (nvmDir.existsSync()) {
          final versions = nvmDir
              .listSync()
              .whereType<Directory>()
              .map((d) => p.join(d.path, 'bin'))
              .toList()
            ..sort();
          for (final bin in versions.reversed) {
            extras.insert(0, bin);
          }
        }
      } catch (_) {}
      env['PATH'] = [...extras, env['PATH'] ?? ''].join(':');
    }
    return env;
  }

  void clear() {
    _lines.clear();
    _exitCode = null;
    notifyListeners();
  }

  Future<void> start({
    required String workingDirectory,
    required RunTarget target,
  }) async {
    if (kIsWeb) {
      _append('[run] Not supported on web.');
      return;
    }
    if (_running) {
      _append('[run] Already running. Stop first.');
      return;
    }

    clear();
    _activeTarget = target;
    _append('\$ ${target.command}');
    _append('cwd: $workingDirectory');
    _append('— offline local process —');

    try {
      final shell = Platform.isWindows ? 'cmd' : '/bin/zsh';
      final args = Platform.isWindows
          ? <String>['/C', target.command]
          : <String>['-lc', target.command];

      final process = await Process.start(
        shell,
        args,
        workingDirectory: workingDirectory,
        runInShell: false,
        environment: _enrichedEnv(),
      );

      _process = process;
      _running = true;
      _exitCode = null;
      notifyListeners();

      _outSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _append(line));
      _errSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => _append(line));

      final code = await process.exitCode;
      await _outSub?.cancel();
      await _errSub?.cancel();
      _outSub = null;
      _errSub = null;
      _process = null;
      _running = false;
      _exitCode = code;
      _append(code == 0 ? '[exit 0]' : '[exit $code]');
      notifyListeners();
    } catch (e) {
      _running = false;
      _process = null;
      _append('[error] $e');
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final process = _process;
    if (process == null) return;
    _append('[run] Stopping…');
    try {
      process.kill(ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_running) {
        process.kill(ProcessSignal.sigkill);
      }
    } catch (e) {
      _append('[run] Stop failed: $e');
    }
  }

  Map<String, String> _enrichedEnv() => enrichedEnv();

  void _append(String line) {
    _lines.add(line);
    if (_lines.length > 4000) {
      _lines.removeRange(0, _lines.length - 4000);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_outSub?.cancel() ?? Future.value());
    unawaited(_errSub?.cancel() ?? Future.value());
    super.dispose();
  }
}
