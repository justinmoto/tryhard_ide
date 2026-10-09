import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/apply_edit_result.dart';
import '../services/code_translator.dart';
import '../services/equivalence_check.dart';
import '../services/next_to_react.dart';
import '../services/ollama_service.dart';
import '../services/run_service.dart';
import '../services/ts_check.dart';
import '../theme/cursor_theme.dart';

/// Convert panel: single-file translation (JS ↔ Python, JS → TS) with a
/// verification badge, and whole-project Next.js → React + Vite migration.
class TranslateSidebar extends StatefulWidget {
  const TranslateSidebar({
    super.key,
    required this.ollama,
    required this.model,
    required this.rootPath,
    required this.openPath,
    required this.readFileContent,
    required this.runService,
    required this.writeFile,
    required this.onOpenFile,
    required this.onOpenFileAt,
    required this.onOpenFolder,
    required this.onRunCommand,
  });

  final OllamaService ollama;
  final String model;
  final String? rootPath;
  final String? openPath;
  /// Live editor text (may be unsaved).
  final String Function() readFileContent;
  final RunService runService;
  final Future<ApplyEditResult> Function(String path, String content) writeFile;
  final ValueChanged<String> onOpenFile;
  final Future<void> Function(String path, int startLine, int endLine) onOpenFileAt;
  final ValueChanged<String> onOpenFolder;
  final void Function(String workingDirectory, RunTarget target) onRunCommand;

  @override
  State<TranslateSidebar> createState() => _TranslateSidebarState();
}

class _TranslateSidebarState extends State<TranslateSidebar> {
  static const _buildTargetId = 'migrate:build';
  static const _green = Color(0xFF3FB950);
  static const _amber = Color(0xFFD29922);
  static const _red = Color(0xFFF85149);

  late final _translator = CodeTranslator(widget.ollama);
  late final _equivalence = EquivalenceCheck(widget.ollama);
  late final _migration = NextToReactMigration(widget.ollama);

  TranslationKind? _kind;
  bool _busy = false;
  bool _cancelRequested = false;
  String? _status;
  String? _error;

  // Last translation (kept when the editor switches to the output file).
  TranslationKind? _doneKind;
  String? _sourcePath;
  String? _sourceCode;
  String? _targetPath;
  EquivalenceReport? _equiv;
  TscReport? _tsc;
  bool _showDetails = false;

  MigrationPlan? _plan;
  bool _planLoading = false;
  bool _migrating = false;
  bool _migrateCancel = false;
  int _migrateDone = 0;
  int _migrateTotal = 0;
  MigrateItem? _migrateCurrent;
  MigrationResult? _migrated;
  bool _showRoutes = false;
  bool _showMigrateFiles = false;
  bool? _buildOk;
  bool _buildWatching = false;

  @override
  void initState() {
    super.initState();
    _kind = _defaultKind();
    widget.runService.addListener(_onRunChanged);
    _loadPlan();
  }

  @override
  void didUpdateWidget(covariant TranslateSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openPath != widget.openPath) {
      final kinds = TranslationKind.forPath(widget.openPath);
      if (!kinds.contains(_kind)) _kind = kinds.firstOrNull;
    }
    if (oldWidget.rootPath != widget.rootPath) {
      _migrated = null;
      _buildOk = null;
      _loadPlan();
    }
    if (oldWidget.runService != widget.runService) {
      oldWidget.runService.removeListener(_onRunChanged);
      widget.runService.addListener(_onRunChanged);
    }
  }

  @override
  void dispose() {
    widget.runService.removeListener(_onRunChanged);
    if (_busy || _migrating) widget.ollama.cancelChat();
    super.dispose();
  }

  TranslationKind? _defaultKind() =>
      TranslationKind.forPath(widget.openPath).firstOrNull;

  void _onRunChanged() {
    final rs = widget.runService;
    if (!_buildWatching || rs.activeTarget?.id != _buildTargetId) return;
    if (!rs.isRunning && rs.exitCode != null) {
      setState(() {
        _buildWatching = false;
        _buildOk = rs.exitCode == 0;
      });
    }
  }

  // ------------------------------------------------------------ translation

  Future<void> _translate() async {
    final kind = _kind;
    final path = widget.openPath;
    if (kind == null || path == null) return;
    final source = widget.readFileContent();
    if (source.trim().isEmpty) {
      setState(() => _error = 'The open file is empty.');
      return;
    }
    final target = kind.targetPath(path);

    _start('Translating with ${widget.model}…');
    try {
      final code = await _translator.translate(kind, source, path, model: widget.model);
      if (_cancelRequested) return;
      if (code.trim().isEmpty) throw Exception('Model returned no code.');
      final written = await widget.writeFile(target, code);
      if (!written.ok) throw Exception(written.error ?? 'Write failed');
      setState(() {
        _doneKind = kind;
        _sourcePath = path;
        _sourceCode = source;
        _targetPath = target;
        _equiv = null;
        _tsc = null;
      });
      await _runCheck();
    } on ChatCancelledException {
      // User pressed Cancel.
    } catch (e) {
      if (mounted) setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      _finish();
    }
  }

  Future<void> _recheck() async {
    _start('Re-checking…');
    try {
      await _runCheck();
    } on ChatCancelledException {
      // Cancelled.
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _finish();
    }
  }

  /// Verifies the translation as it is on disk (picks up manual edits).
  Future<void> _runCheck() async {
    final kind = _doneKind!;
    final target = _targetPath!;
    final translated = await File(target).readAsString();
    if (kind.check == TranslationCheck.tsc) {
      _setStatus('Running tsc --noEmit…');
      final report = await TsCheck.run(target, rootPath: widget.rootPath);
      if (!mounted) return;
      setState(() {
        _tsc = report;
        _showDetails = !report.clean;
      });
    } else {
      final report = await _equivalence.run(
        sourceLang: kind == TranslationKind.jsToPython ? Lang.js : Lang.python,
        sourceCode: _sourceCode!,
        targetCode: translated,
        sourcePath: _sourcePath!,
        model: widget.model,
        onStatus: _setStatus,
      );
      if (!mounted || _cancelRequested) return;
      setState(() {
        _equiv = report;
        _showDetails = !report.allMatch;
      });
    }
  }

  Future<void> _fix() async {
    final kind = _doneKind;
    final target = _targetPath;
    if (kind == null || target == null) return;
    final feedback = kind.check == TranslationCheck.tsc
        ? _tsc?.feedback() ?? ''
        : _equiv?.feedback() ?? '';
    if (feedback.trim().isEmpty) return;

    _start('Asking ${widget.model} to fix…');
    try {
      final current = await File(target).readAsString();
      final code = await _translator.repair(
        kind,
        _sourceCode!,
        _sourcePath!,
        current,
        feedback,
        model: widget.model,
      );
      if (_cancelRequested) return;
      if (code.trim().isEmpty) throw Exception('Model returned no code.');
      final written = await widget.writeFile(target, code);
      if (!written.ok) throw Exception(written.error ?? 'Write failed');
      await _runCheck();
    } on ChatCancelledException {
      // Cancelled.
    } catch (e) {
      if (mounted) setState(() => _error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      _finish();
    }
  }

  void _start(String status) {
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _status = status;
      _error = null;
    });
  }

  void _setStatus(String status) {
    if (mounted) setState(() => _status = status);
  }

  void _finish() {
    if (mounted) {
      setState(() {
        _busy = false;
        _status = null;
      });
    }
  }

  void _cancel() {
    _cancelRequested = true;
    widget.ollama.cancelChat();
    setState(() => _status = 'Cancelling…');
  }

  // -------------------------------------------------------------- migration

  Future<void> _loadPlan() async {
    final root = widget.rootPath;
    if (root == null) {
      setState(() => _plan = null);
      return;
    }
    setState(() => _planLoading = true);
    final plan = await NextToReactMigration.plan(root);
    if (!mounted || widget.rootPath != root) return;
    setState(() {
      _plan = plan;
      _planLoading = false;
    });
  }

  Future<void> _migrate() async {
    final plan = _plan;
    if (plan == null) return;
    setState(() {
      _migrating = true;
      _migrateCancel = false;
      _migrated = null;
      _buildOk = null;
      _migrateDone = 0;
      _migrateTotal = plan.items.length;
    });
    try {
      final result = await _migration.execute(
        plan,
        model: widget.model,
        isCancelled: () => _migrateCancel,
        onProgress: (done, total, item) {
          if (!mounted) return;
          setState(() {
            _migrateDone = done;
            _migrateTotal = total;
            _migrateCurrent = item;
          });
        },
      );
      if (!mounted) return;
      setState(() => _migrated = result);
    } on ChatCancelledException {
      if (mounted) {
        setState(() => _migrated = MigrationResult(
              outputDir: plan.outputDir,
              leftoverNextImports: const [],
              cancelled: true,
            ));
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Migration failed: $e');
    } finally {
      if (mounted) setState(() => _migrating = false);
    }
  }

  void _cancelMigration() {
    _migrateCancel = true;
    widget.ollama.cancelChat();
  }

  void _installAndBuild() {
    final out = _migrated?.outputDir;
    if (out == null) return;
    setState(() {
      _buildWatching = true;
      _buildOk = null;
    });
    widget.onRunCommand(
      out,
      const RunTarget(
        id: _buildTargetId,
        label: 'npm install && vite build',
        command: 'npm install && npm run build',
      ),
    );
  }

  // --------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CursorColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 35,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    'CONVERT',
                    style: TextStyle(
                      color: CursorColors.fg,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: [
                _sectionLabel('FILE'),
                ..._fileSection(),
                const SizedBox(height: 18),
                _sectionLabel('PROJECT'),
                ..._projectSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            color: CursorColors.fgDim,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      );

  List<Widget> _fileSection() {
    final path = widget.openPath;
    final kinds = TranslationKind.forPath(path);
    final kind = _kind;
    final widgets = <Widget>[];

    if (path == null || kinds.isEmpty) {
      widgets.add(_hint(
        path == null
            ? 'Open a .js or .py file to translate it.'
            : '${p.basename(path)} has no translator. Supported: .js .mjs .cjs .jsx .py',
      ));
    } else {
      widgets.add(Text(
        p.basename(path),
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: CursorColors.fgBright, fontSize: 12, fontWeight: FontWeight.w600),
      ));
      widgets.add(const SizedBox(height: 8));
      widgets.add(Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final k in kinds)
            _Chip(
              label: k.label,
              selected: k == kind,
              onTap: _busy ? null : () => setState(() => _kind = k),
            ),
        ],
      ));
      if (kind != null) {
        final target = kind.targetPath(path);
        final exists = File(target).existsSync();
        widgets.add(const SizedBox(height: 8));
        widgets.add(_kv('Writes', p.basename(target)));
        widgets.add(_kv(
          'Check',
          kind.check == TranslationCheck.tsc
              ? 'tsc --noEmit'
              : 'run both on the same inputs',
        ));
        if (exists) {
          widgets.add(Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${p.basename(target)} exists. It is replaced, and Discard in the diff restores it.',
              style: const TextStyle(color: _amber, fontSize: 11, height: 1.35),
            ),
          ));
        }
        widgets.add(const SizedBox(height: 10));
        widgets.add(Row(
          children: [
            _PrimaryButton(
              label: 'Translate',
              icon: Icons.translate,
              onTap: _busy || _migrating ? null : _translate,
            ),
          ],
        ));
      }
    }

    if (_busy) widgets.add(_progressRow(_status ?? 'Working…', onCancel: _cancel));
    if (_error != null) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: SelectableText(_error!, style: const TextStyle(color: _red, fontSize: 11, height: 1.35)),
      ));
    }
    if (_targetPath != null) widgets.add(_resultCard());
    return widgets;
  }

  Widget _resultCard() {
    final kind = _doneKind!;
    final target = _targetPath!;
    final (badge, canFix) = _badge();

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CursorColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CursorColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => widget.onOpenFile(target),
            child: Text(
              '${p.basename(_sourcePath!)} → ${p.basename(target)}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: CursorColors.fgBright, fontSize: 12, decoration: TextDecoration.underline, decorationColor: CursorColors.fgDim),
            ),
          ),
          const SizedBox(height: 8),
          if (badge != null)
            InkWell(
              onTap: () => setState(() => _showDetails = !_showDetails),
              child: Row(
                children: [
                  badge,
                  const SizedBox(width: 6),
                  Icon(
                    _showDetails ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: CursorColors.fgMuted,
                  ),
                ],
              ),
            ),
          if (_showDetails) ..._details(kind),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _TextAction(label: 'Re-check', onTap: _busy ? null : _recheck),
              if (canFix)
                _TextAction(label: 'Fix with model', onTap: _busy ? null : _fix),
              _TextAction(label: 'Open source', onTap: () => widget.onOpenFile(_sourcePath!)),
            ],
          ),
        ],
      ),
    );
  }

  /// The verification badge, and whether the model can be asked to fix it.
  (Widget?, bool) _badge() {
    final equiv = _equiv;
    final tsc = _tsc;
    if (equiv != null) {
      if (equiv.error != null) {
        return (_Badge(icon: Icons.help_outline, label: 'Tests not run', color: CursorColors.fgMuted), false);
      }
      final color = equiv.allMatch ? _green : (equiv.matched == 0 ? _red : _amber);
      return (
        _Badge(
          icon: equiv.allMatch ? Icons.check_circle : Icons.error_outline,
          label: 'Tests match ${equiv.matched}/${equiv.total}',
          color: color,
        ),
        !equiv.allMatch,
      );
    }
    if (tsc != null) {
      if (tsc.error != null) {
        return (_Badge(icon: Icons.help_outline, label: 'tsc did not run', color: CursorColors.fgMuted), false);
      }
      final n = tsc.diagnostics.length;
      return (
        _Badge(
          icon: n == 0 ? Icons.check_circle : Icons.error_outline,
          label: n == 0 ? 'tsc --noEmit clean' : 'tsc: $n error${n == 1 ? '' : 's'}',
          color: n == 0 ? _green : _red,
        ),
        n > 0,
      );
    }
    return (null, false);
  }

  List<Widget> _details(TranslationKind kind) {
    final mono = TextStyle(fontFamily: 'Menlo', fontSize: 11, color: CursorColors.fg, height: 1.35);
    final out = <Widget>[const SizedBox(height: 8)];
    final equiv = _equiv;
    final tsc = _tsc;

    if (equiv != null) {
      if (equiv.error != null) {
        out.add(SelectableText(equiv.error!, style: mono.copyWith(color: CursorColors.fgMuted)));
        return out;
      }
      final from = kind.from == 'Python' ? 'py' : 'js';
      final to = kind.to == 'Python' ? 'py' : 'js';
      for (final c in equiv.cases) {
        out.add(Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(c.matches ? Icons.check : Icons.close, size: 13, color: c.matches ? _green : _red),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText.rich(
                  TextSpan(
                    style: mono,
                    children: [
                      TextSpan(text: c.testCase.call, style: TextStyle(color: CursorColors.fgBright)),
                      if (c.matches)
                        TextSpan(text: '\n→ ${c.source}', style: TextStyle(color: CursorColors.fgMuted))
                      else ...[
                        TextSpan(text: '\n$from: ${c.source}', style: TextStyle(color: CursorColors.fgMuted)),
                        TextSpan(text: '\n$to: ${c.target}', style: const TextStyle(color: _red)),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ));
      }
      out.add(_hint('Inputs come from the model; outputs come from running node and python.'));
    }

    if (tsc != null) {
      if (tsc.error != null) {
        out.add(SelectableText(tsc.error!, style: mono.copyWith(color: CursorColors.fgMuted)));
        return out;
      }
      for (final d in tsc.diagnostics.take(50)) {
        out.add(InkWell(
          onTap: () => widget.onOpenFileAt(_targetPath!, d.line, d.line),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Text.rich(
              TextSpan(style: mono, children: [
                TextSpan(text: 'L${d.line} ${d.code} ', style: const TextStyle(color: _red)),
                TextSpan(text: d.message),
              ]),
            ),
          ),
        ));
      }
      out.add(_hint([
        'via ${tsc.tool}',
        if (tsc.otherFileErrors > 0) '${tsc.otherFileErrors} more error(s) in imported files',
      ].join(' · ')));
    }
    return out;
  }

  List<Widget> _projectSection() {
    if (widget.rootPath == null) return [_hint('Open a folder to migrate a project.')];
    if (_planLoading) return [_progressRow('Scanning project…')];
    final plan = _plan;
    if (plan == null) {
      return [_hint('Open a Next.js project to migrate it to React + Vite.')];
    }

    final widgets = <Widget>[
      Text(
        'Next.js → React + Vite',
        style: TextStyle(color: CursorColors.fgBright, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      _kv('Router', plan.routerLabel.isEmpty ? 'none found' : plan.routerLabel),
      _kv('Routes', '${plan.routes.length}'),
      _kv('Files', '${plan.items.length}'),
      _kv('Output', '${p.basename(plan.outputDir)}/'),
      const SizedBox(height: 4),
      InkWell(
        onTap: () => setState(() => _showRoutes = !_showRoutes),
        child: Row(
          children: [
            Icon(_showRoutes ? Icons.expand_less : Icons.expand_more, size: 15, color: CursorColors.fgMuted),
            Text('Route map', style: TextStyle(color: CursorColors.fgMuted, fontSize: 11)),
          ],
        ),
      ),
      if (_showRoutes)
        for (final r in plan.routes)
          InkWell(
            onTap: () => widget.onOpenFile(p.joinAll([plan.root, ...r.file.split('/')])),
            child: Padding(
              padding: const EdgeInsets.only(left: 4, top: 3),
              child: Text.rich(
                TextSpan(
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
                  children: [
                    TextSpan(text: r.path, style: TextStyle(color: CursorColors.fgBright)),
                    TextSpan(text: '  ${r.file}', style: TextStyle(color: CursorColors.fgDim)),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      const SizedBox(height: 10),
    ];

    if (_migrating) {
      final cur = _migrateCurrent;
      widgets.add(ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: _migrateTotal == 0 ? null : _migrateDone / _migrateTotal,
          minHeight: 3,
          color: CursorColors.accentSoft,
          backgroundColor: CursorColors.border,
        ),
      ));
      widgets.add(_progressRow(
        cur == null ? 'Starting…' : '$_migrateDone/$_migrateTotal  ${cur.rel}',
        onCancel: _cancelMigration,
      ));
      return widgets;
    }

    widgets.add(Row(
      children: [
        _PrimaryButton(
          label: _migrated == null ? 'Migrate' : 'Migrate again',
          icon: Icons.drive_file_move_outline,
          onTap: _busy
              ? null
              : () async {
                  if (_migrated != null) await _loadPlan();
                  await _migrate();
                },
        ),
      ],
    ));
    widgets.add(Padding(
      padding: const EdgeInsets.only(top: 6),
      child: _hint('The original project is not modified. Rewrite rules run first, and the model only handles files that still use Next.js APIs.'),
    ));

    final done = _migrated;
    if (done != null) widgets.add(_migrationCard(plan, done));
    return widgets;
  }

  Widget _migrationCard(MigrationPlan plan, MigrationResult done) {
    final leftovers = done.leftoverNextImports;
    final failed = plan.items.where((i) => i.failed).toList();
    final changed = plan.items
        .where((i) => i.action == MigrateAction.rules || i.action == MigrateAction.model || i.failed)
        .toList();

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CursorColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CursorColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (done.cancelled)
            const _Badge(icon: Icons.cancel_outlined, label: 'Cancelled (partial output)', color: _amber)
          else ...[
            _Badge(
              icon: leftovers.isEmpty ? Icons.check_circle : Icons.error_outline,
              label: leftovers.isEmpty
                  ? 'No next/* imports left'
                  : '${leftovers.length} file${leftovers.length == 1 ? '' : 's'} still import next/*',
              color: leftovers.isEmpty ? _green : _amber,
            ),
            if (_buildOk != null || _buildWatching) ...[
              const SizedBox(height: 6),
              _Badge(
                icon: _buildWatching
                    ? Icons.hourglass_top
                    : (_buildOk! ? Icons.check_circle : Icons.error_outline),
                label: _buildWatching
                    ? 'vite build running…'
                    : (_buildOk! ? 'vite build passed' : 'vite build failed (see Run panel)'),
                color: _buildWatching ? CursorColors.fgMuted : (_buildOk! ? _green : _red),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '${plan.count(MigrateAction.copy)} copied · ${plan.count(MigrateAction.rules)} rewritten · '
              '${plan.count(MigrateAction.model)} by model · ${plan.count(MigrateAction.skip)} skipped'
              '${failed.isEmpty ? '' : ' · ${failed.length} need review'}',
              style: TextStyle(color: CursorColors.fgMuted, fontSize: 11, height: 1.35),
            ),
            for (final rel in leftovers)
              _fileLink(done.outputDir, rel, color: _amber),
            if (changed.isNotEmpty) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => setState(() => _showMigrateFiles = !_showMigrateFiles),
                child: Row(
                  children: [
                    Icon(_showMigrateFiles ? Icons.expand_less : Icons.expand_more, size: 15, color: CursorColors.fgMuted),
                    Text('Changed files (${changed.length})', style: TextStyle(color: CursorColors.fgMuted, fontSize: 11)),
                  ],
                ),
              ),
              if (_showMigrateFiles)
                for (final i in changed)
                  _fileLink(
                    done.outputDir,
                    i.rel,
                    note: i.reason,
                    color: i.failed ? _red : null,
                  ),
            ],
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _TextAction(
                label: 'Open report',
                onTap: () => widget.onOpenFile(p.join(done.outputDir, 'MIGRATION.md')),
              ),
              if (!done.cancelled)
                _TextAction(
                  label: 'Install & build',
                  onTap: _buildWatching ? null : _installAndBuild,
                ),
              _TextAction(
                label: 'Open as workspace',
                onTap: () => widget.onOpenFolder(done.outputDir),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fileLink(String root, String rel, {String? note, Color? color}) {
    // Renamed configs (.js → .cjs) live under a different name in the output.
    var path = p.joinAll([root, ...rel.split('/')]);
    if (!File(path).existsSync() && File('${p.withoutExtension(path)}.cjs').existsSync()) {
      path = '${p.withoutExtension(path)}.cjs';
    }
    return InkWell(
      onTap: () => widget.onOpenFile(path),
      child: Padding(
        padding: const EdgeInsets.only(top: 4, left: 2),
        child: Text.rich(
          TextSpan(
            style: const TextStyle(fontSize: 11, height: 1.3),
            children: [
              TextSpan(text: rel, style: TextStyle(color: color ?? CursorColors.fg, fontFamily: 'Menlo')),
              if (note != null) TextSpan(text: '  $note', style: TextStyle(color: CursorColors.fgDim)),
            ],
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _progressRow(String text, {VoidCallback? onCancel}) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: CursorColors.fgMuted),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
              ),
            ),
            if (onCancel != null) _TextAction(label: 'Cancel', onTap: onCancel),
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: Text(k, style: TextStyle(color: CursorColors.fgDim, fontSize: 11)),
            ),
            Expanded(
              child: Text(
                v,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: CursorColors.fg, fontSize: 11),
              ),
            ),
          ],
        ),
      );

  Widget _hint(String text) => Text(
        text,
        style: TextStyle(color: CursorColors.fgDim, fontSize: 11, height: 1.4),
      );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? CursorColors.active : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? CursorColors.accentSoft : CursorColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? CursorColors.fgBright : CursorColors.fgMuted,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.icon, required this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: enabled ? CursorColors.accent : CursorColors.hover,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: enabled ? Colors.white : CursorColors.fgDim),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? Colors.white : CursorColors.fgDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: onTap == null ? CursorColors.fgDim : CursorColors.accentSoft,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
