import 'dart:io';

import 'package:code_text_field/code_text_field.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../editor/syntax.dart';
import '../services/apply_edit_result.dart';
import '../services/edit_proposal.dart';
import '../services/file_resolver.dart';
import '../services/folder_picker.dart';
import '../services/ollama_service.dart';
import '../services/repo_index.dart';
import '../services/run_service.dart';
import '../services/workspace_prefs.dart';
import '../theme/cursor_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/activity_bar.dart';
import '../widgets/chat_sidebar.dart';
import '../widgets/editor_diff_view.dart';
import '../widgets/file_explorer_sidebar.dart';
import '../widgets/run_panel.dart';
import '../widgets/search_sidebar.dart';
import '../widgets/top_toast.dart';
import '../widgets/transparency_panel.dart';

class IdeShell extends StatefulWidget {
  const IdeShell({super.key});

  @override
  State<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends State<IdeShell> {
  final _ollama = OllamaService();
  late final _repoIndex = RepoIndex(_ollama);
  final _runService = RunService();
  late final CodeController _editor = CodeController();
  final _pathController = TextEditingController();
  final _editorFocus = FocusNode();

  static const _imageExts = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico',
  };
  static const _binaryExts = {
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico',
    '.pdf', '.zip', '.jar', '.war', '.class', '.exe', '.dll', '.so',
    '.dylib', '.o', '.a', '.wasm', '.mp3', '.mp4', '.mov', '.wav',
    '.ttf', '.otf', '.woff', '.woff2', '.eot', '.7z', '.rar', '.gz',
    '.tar', '.apk', '.ipa', '.dmg', '.app', '.bin', '.dat', '.db',
    '.sqlite', '.pyc', '.pyo', '.parcel', '.snap',
  };

  static const _defaultSidebarWidth = 260.0;
  static const _defaultChatWidth = 380.0;
  static const _minSidebarWidth = 180.0;
  static const _maxSidebarWidth = 480.0;
  static const _minChatWidth = 280.0;
  static const _maxChatWidth = 640.0;

  OllamaStatus? _status;
  String? _openPath;
  String? _rootPath;
  String _savedContent = '';
  String _selection = '';
  bool _sidebarOpen = true;
  bool _chatOpen = true;
  bool _runOpen = false;
  bool _isImagePreview = false;
  bool _dirty = false;
  bool _showEditorDiff = false;
  ApplyEditResult? _editorDiff;
  ActivityItem _activity = ActivityItem.explorer;
  double _sidebarWidth = _defaultSidebarWidth;
  double _chatWidth = _defaultChatWidth;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onEditorChanged);
    _refreshOllama();
    _restoreLastFolder();
  }

  Future<void> _restoreLastFolder() async {
    if (kIsWeb) return;
    final path = await WorkspacePrefs.loadLastFolder();
    if (path == null || !mounted) return;
    final dir = Directory(path);
    if (!await dir.exists()) {
      await WorkspacePrefs.clearLastFolder();
      return;
    }
    if (!mounted) return;
    setState(() {
      _rootPath = dir.path;
      _sidebarOpen = true;
      _activity = ActivityItem.explorer;
    });
  }

  void _onEditorChanged() {
    final sel = _editor.selection;
    final next = (!sel.isValid || sel.isCollapsed)
        ? ''
        : sel.textInside(_editor.text);
    final dirty = _openPath != null &&
        !_isImagePreview &&
        _editor.text != _savedContent;
    if (next != _selection || dirty != _dirty) {
      setState(() {
        _selection = next;
        _dirty = dirty;
      });
    }
  }

  @override
  void dispose() {
    _editor.removeListener(_onEditorChanged);
    _editor.dispose();
    _editorFocus.dispose();
    _pathController.dispose();
    _runService.dispose();
    _repoIndex.cancel();
    _repoIndex.dispose();
    super.dispose();
  }

  /// Open [path] (if not already open) and select lines [startLine]..[endLine].
  Future<void> _openFileAt(String path, int startLine, int endLine) async {
    final alreadyOpen = _openPath != null && p.equals(_openPath!, path);
    if (!alreadyOpen) await _openFile(path);
    if (!mounted || _openPath == null || !p.equals(_openPath!, path)) return;
    if (_isImagePreview) return;

    if (_showEditorDiff) setState(() => _showEditorDiff = false);

    final text = _editor.text;
    int offsetOfLine(int line) {
      var offset = 0;
      for (var i = 1; i < line; i++) {
        final next = text.indexOf('\n', offset);
        if (next == -1) return text.length;
        offset = next + 1;
      }
      return offset;
    }

    final start = offsetOfLine(startLine.clamp(1, 1 << 30));
    var end = text.indexOf('\n', offsetOfLine(endLine.clamp(startLine, 1 << 30)));
    if (end == -1) end = text.length;
    _editor.selection = TextSelection(baseOffset: start, extentOffset: end);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editorFocus.requestFocus();
    });
  }

  Future<void> _quickRun() async {
    if (_rootPath == null) {
      _snack('Open a folder first, then Run.');
      setState(() => _runOpen = true);
      return;
    }
    setState(() => _runOpen = true);
    if (_runService.isRunning) {
      await _runService.stop();
      return;
    }
    final targets = await RunService.detectTargets(_rootPath);
    if (!mounted || targets.isEmpty) return;
    await _runService.start(workingDirectory: _rootPath!, target: targets.first);
  }

  void _setEditorContent(String content, {String? path, bool markSaved = true}) {
    _editor.language = languageForPath(path);
    _editor.text = content;
    if (markSaved) {
      _savedContent = content;
      _dirty = false;
    }
  }

  Future<void> _refreshOllama() async {
    final status = await _ollama.checkStatus();
    if (!mounted) return;
    setState(() => _status = status);
    if (status.models.contains(_ollama.chatModel) == false &&
        status.models.isNotEmpty) {
      final coder = status.models.firstWhere(
        (m) => m.contains('coder') || m.contains('qwen'),
        orElse: () => status.models.first,
      );
      _ollama.chatModel = coder;
    }
  }

  bool _looksBinary(List<int> bytes) {
    final sample = bytes.length > 8000 ? bytes.sublist(0, 8000) : bytes;
    if (sample.contains(0)) return true;
    var weird = 0;
    for (final b in sample) {
      if (b == 9 || b == 10 || b == 13) continue;
      if (b < 32 || b == 0x7F) weird++;
    }
    return weird > sample.length * 0.05;
  }

  Future<void> _openFile([String? pathOverride]) async {
    final raw = (pathOverride ?? _pathController.text).trim();
    if (raw.isEmpty) return;
    if (kIsWeb) {
      _snack('File open is desktop/mobile only.');
      return;
    }
    try {
      final file = File(raw);
      if (!await file.exists()) {
        _snack('File not found: $raw');
        return;
      }

      final ext = p.extension(raw).toLowerCase();
      if (_imageExts.contains(ext)) {
        setState(() {
          _openPath = raw;
          _pathController.text = raw;
          _setEditorContent('', path: null);
          _selection = '';
          _isImagePreview = true;
          _dirty = false;
          _rootPath ??= p.dirname(raw);
        });
        return;
      }

      if (_binaryExts.contains(ext)) {
        _snack('Cannot open binary file: ${p.basename(raw)}');
        return;
      }

      final bytes = await file.readAsBytes();
      if (_looksBinary(bytes)) {
        _snack('Cannot open binary file: ${p.basename(raw)}');
        return;
      }

      final content = await file.readAsString();
      setState(() {
        _openPath = raw;
        _pathController.text = raw;
        _setEditorContent(content, path: raw);
        _selection = '';
        _isImagePreview = false;
        _rootPath ??= p.dirname(raw);
      });
    } catch (e) {
      final name = p.basename(raw);
      if ('$e'.contains('utf-8') || '$e'.contains('UTF-8')) {
        _snack('Cannot open binary file: $name');
      } else {
        _snack('Open failed: $e');
      }
    }
  }

  Future<void> _pickFolder() async {
    if (kIsWeb) {
      _snack('Folders are desktop/mobile only.');
      return;
    }
    if (_rootPath != null) {
      final confirmed = await _confirmChangeFolder();
      if (!confirmed || !mounted) return;
    }
    final path = await FolderPicker.pick(initialDirectory: _rootPath);
    if (path == null) return;
    await _openFolder(path, clearOpenFile: _rootPath != null);
  }

  Future<bool> _confirmChangeFolder() async {
    final folderName = p.basename(_rootPath!);
    final dirtyNote = _dirty
        ? '\n\nYou have unsaved changes that will be discarded.'
        : '';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: CursorColors.panel,
        title: Text(
          'Change Folder?',
          style: TextStyle(color: CursorColors.fgBright, fontSize: 16),
        ),
        content: Text(
          'Open a different folder instead of "$folderName"? '
          'The currently open file will be closed.$dirtyNote',
          style: TextStyle(color: CursorColors.fg, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: CursorColors.fgMuted),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Change Folder',
              style: TextStyle(color: CursorColors.accent),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _openFolder(String path, {bool clearOpenFile = false}) async {
    if (kIsWeb) {
      _snack('Folders are desktop/mobile only.');
      return;
    }
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        _snack('Folder not found: $path');
        return;
      }
      // Touch-list to verify sandbox access after picker grant.
      dir.listSync(followLinks: false);
      setState(() {
        if (clearOpenFile) {
          _showEditorDiff = false;
          _editorDiff = null;
          _openPath = null;
          _pathController.clear();
          _selection = '';
          _setEditorContent('', path: null);
          _isImagePreview = false;
          _dirty = false;
        }
        _rootPath = dir.path;
        _sidebarOpen = true;
        _activity = ActivityItem.explorer;
      });
      await WorkspacePrefs.saveLastFolder(dir.path);
    } catch (e) {
      _snack('Open folder failed: $e');
    }
  }

  Future<void> _save() async {
    if (_openPath == null || kIsWeb) {
      _snack('Open a file first to save.');
      return;
    }
    if (_isImagePreview) {
      _snack('Image files are preview-only.');
      return;
    }
    final path = _openPath!;
    final content = _editor.text;
    try {
      final file = File(path);
      await file.writeAsString(content, flush: true);
      if (!mounted) return;
      setState(() {
        _savedContent = content;
        _dirty = false;
      });
      _snack('Saved ${p.basename(path)}');
    } on FileSystemException catch (e) {
      final denied = '${e.osError}'.contains('Operation not permitted') ||
          '${e.osError}'.contains('Permission denied') ||
          e.message.contains('Cannot open file');
      _snack(
        denied
            ? 'Save blocked by macOS. Re-open the folder, then try again.'
            : 'Save failed: ${e.message}',
      );
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  void _closeFile() {
    setState(() {
      _showEditorDiff = false;
      _editorDiff = null;
      _openPath = null;
      _pathController.clear();
      _selection = '';
      _setEditorContent('', path: null);
      _isImagePreview = false;
      _dirty = false;
    });
  }

  String? _fileName() => _openPath == null ? null : p.basename(_openPath!);

  void _snack(String message) {
    showTopToast(context, message);
  }

  Future<ApplyEditResult> _applyEdit(
    EditProposal proposal, {
    String? userPrompt,
  }) async {
    if (kIsWeb) {
      return ApplyEditResult.fail('Apply edit is desktop/mobile only.');
    }

    final path = await FileResolver.resolve(
      rootPath: _rootPath,
      hint: proposal.targetHint,
      openPath: _openPath,
      userPrompt: userPrompt,
    );
    if (path == null) {
      return ApplyEditResult.fail(
        'Could not find target file. Open a folder / mention the filename (e.g. lib/main.dart).',
      );
    }

    String oldContent = '';
    try {
      final file = File(path);
      if (await file.exists()) {
        oldContent = await file.readAsString();
      }
    } catch (e) {
      return ApplyEditResult.fail('Could not read $path: $e');
    }

    final isOpen = _openPath != null &&
        p.equals(_openPath!, path) &&
        !_isImagePreview;
    var next = proposal.applyTo(
      isOpen ? _editor.text : oldContent,
      selection: isOpen ? _editor.selection : null,
    );
    next ??= proposal.newText;
    if (next.trim().isEmpty) {
      return ApplyEditResult.fail('Apply failed — empty edit.');
    }

    try {
      await File(path).writeAsString(next, flush: true);
    } catch (e) {
      return ApplyEditResult.fail('Write failed: $e');
    }

    if (!mounted) {
      return ApplyEditResult(
        ok: true,
        path: path,
        oldContent: oldContent,
        newContent: next,
      );
    }

    final result = ApplyEditResult(
      ok: true,
      path: path,
      oldContent: oldContent,
      newContent: next,
    );

    if (isOpen) {
      setState(() {
        _setEditorContent(next!, path: path, markSaved: true);
        _selection = '';
        _editorDiff = result;
        _showEditorDiff = true;
      });
    } else {
      await _openFile(path);
      if (!mounted) return result;
      setState(() {
        _editorDiff = result;
        _showEditorDiff = true;
      });
    }

    _snack('Updated ${p.basename(path)} — viewing diff in editor');
    return result;
  }

  void _keepEditorDiff() {
    setState(() {
      _showEditorDiff = false;
      // Keep result so DIFF tab can reopen until next edit.
    });
    _snack('Changes kept');
  }

  Future<void> _discardEditorDiff() async {
    final diff = _editorDiff;
    if (diff == null || !diff.ok || diff.path == null) {
      setState(() {
        _showEditorDiff = false;
        _editorDiff = null;
      });
      return;
    }
    final path = diff.path!;
    final previous = diff.oldContent ?? '';
    try {
      await File(path).writeAsString(previous, flush: true);
    } catch (e) {
      _snack('Discard failed: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      if (_openPath != null && p.equals(_openPath!, path)) {
        _setEditorContent(previous, path: path, markSaved: true);
      }
      _showEditorDiff = false;
      _editorDiff = null;
      _selection = '';
    });
    _snack('Discarded — reverted ${p.basename(path)}');
  }

  void _onActivity(ActivityItem item) {
    setState(() {
      if (_activity == item && _sidebarOpen) {
        _sidebarOpen = false;
      } else {
        _activity = item;
        _sidebarOpen = true;
      }
    });
  }

  Widget _buildEditorBody() {
    if (_openPath == null) {
      return Center(
        child: Text(
          'Try Hard IDE',
          style: TextStyle(
            color: CursorColors.fgDim,
            fontSize: 28,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        ),
      );
    }
    if (_isImagePreview) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Image.file(
            File(_openPath!),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stack) => Text(
              'Could not preview image',
              style: TextStyle(color: CursorColors.fgMuted),
            ),
          ),
        ),
      );
    }

    final diff = _editorDiff;
    final showDiff = _showEditorDiff &&
        diff != null &&
        diff.ok &&
        diff.path != null &&
        p.equals(diff.path!, _openPath!);

    if (showDiff) {
      return EditorDiffView(
        path: diff.path!,
        oldContent: diff.oldContent ?? '',
        newContent: diff.newContent ?? _editor.text,
        onKeep: _keepEditorDiff,
        onDiscard: _discardEditorDiff,
      );
    }

    return CodeTheme(
      data: CodeThemeData(
        styles: syntaxTheme(dark: CursorColors.isDark),
      ),
      child: CodeField(
        controller: _editor,
        focusNode: _editorFocus,
        expands: true,
        wrap: false,
        background: CursorColors.editor,
        cursorColor: CursorColors.accentSoft,
        textStyle: TextStyle(
          fontFamily: 'Menlo',
          fontSize: 13,
          color: CursorColors.fgBright,
          height: 1.45,
        ),
        lineNumberStyle: LineNumberStyle(
          width: 48,
          textStyle: TextStyle(
            color: CursorColors.fgDim,
            fontSize: 12,
            fontFamily: 'Menlo',
          ),
          background: CursorColors.editor,
        ),
        padding: const EdgeInsets.only(top: 8, bottom: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    CursorColors.bindFrom(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final editorPane = Column(
      children: [
        _tabBar(),
        Expanded(
          child: ColoredBox(
            color: CursorColors.editor,
            child: _buildEditorBody(),
          ),
        ),
      ],
    );

    final Widget sidebar = switch (_activity) {
      ActivityItem.search => SearchSidebar(
          rootPath: _rootPath,
          onOpenFile: (path) => _openFile(path),
        ),
      ActivityItem.explorer => FileExplorerSidebar(
          rootPath: _rootPath,
          openPath: _openPath,
          onOpenFile: (path) => _openFile(path),
          onPickFolder: _pickFolder,
        ),
    };

    final chat = ChatSidebar(
      ollama: _ollama,
      repoIndex: _repoIndex,
      rootPath: _rootPath,
      openPath: _openPath,
      openFileName: _fileName(),
      selection: _selection,
      fileContent: _editor.text,
      models: _status?.models ?? const [],
      onModelChanged: (m) => setState(() => _ollama.chatModel = m),
      onRefreshModels: _refreshOllama,
      onClose: () => setState(() => _chatOpen = false),
      applyEdit: _applyEdit,
      onOpenFile: (path) => _openFile(path),
      onOpenFileAt: _openFileAt,
      onDiscardEdit: (result) async {
        if (_editorDiff?.path == result.path) {
          await _discardEditorDiff();
        } else {
          // Discard a chat result that may not be the active editor diff.
          final path = result.path;
          if (path == null) return;
          try {
            await File(path).writeAsString(result.oldContent ?? '', flush: true);
            if (!mounted) return;
            if (_openPath != null && p.equals(_openPath!, path)) {
              setState(() {
                _setEditorContent(result.oldContent ?? '', path: path, markSaved: true);
                _showEditorDiff = false;
                _editorDiff = null;
              });
            }
            _snack('Discarded — reverted ${p.basename(path)}');
          } catch (e) {
            _snack('Discard failed: $e');
          }
        }
      },
      onKeepEdit: (result) {
        if (_editorDiff?.path == result.path) {
          _keepEditorDiff();
        } else {
          _snack('Changes kept for ${p.basename(result.path ?? 'file')}');
        }
      },
    );

    final workbench = wide
        ? Row(
            children: [
              ActivityBar(
                active: _activity,
                explorerOpen: _sidebarOpen,
                chatOpen: _chatOpen,
                onSelect: _onActivity,
                onToggleChat: () => setState(() => _chatOpen = !_chatOpen),
              ),
              if (_sidebarOpen) ...[
                SizedBox(
                  width: _sidebarWidth,
                  child: sidebar,
                ),
                _VerticalResizeHandle(
                  onDrag: (dx) {
                    setState(() {
                      _sidebarWidth = (_sidebarWidth + dx).clamp(
                        _minSidebarWidth,
                        _maxSidebarWidth,
                      );
                    });
                  },
                ),
              ],
              Expanded(child: editorPane),
              if (_chatOpen) ...[
                _VerticalResizeHandle(
                  onDrag: (dx) {
                    setState(() {
                      _chatWidth = (_chatWidth - dx).clamp(
                        _minChatWidth,
                        _maxChatWidth,
                      );
                    });
                  },
                ),
                SizedBox(
                  width: _chatWidth,
                  child: chat,
                ),
              ],
            ],
          )
        : Column(
            children: [
              if (_sidebarOpen)
                Flexible(
                  flex: 28,
                  child: sidebar,
                ),
              Flexible(
                flex: 36,
                child: editorPane,
              ),
              if (_chatOpen)
                Flexible(
                  flex: 36,
                  child: chat,
                ),
            ],
          );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _quickRun,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): _quickRun,
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): () {
          setState(() => _runOpen = !_runOpen);
        },
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): () {
          setState(() => _runOpen = !_runOpen);
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: CursorColors.bg,
          body: Column(
            children: [
              _titleBar(),
              Expanded(child: workbench),
              if (_runOpen)
                SizedBox(
                  height: 220,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: CursorColors.border),
                      ),
                    ),
                    child: RunPanel(
                      runService: _runService,
                      rootPath: _rootPath,
                      onClose: () => setState(() => _runOpen = false),
                    ),
                  ),
                ),
              TransparencyPanel(
                status: _status,
                model: _ollama.chatModel,
                fileName: _fileName(),
                onModelChanged: (m) => setState(() => _ollama.chatModel = m),
                onRefresh: _refreshOllama,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleBar() {
    const trafficLightInset = 78.0;
    return Container(
      height: 38,
      color: CursorColors.titleBar,
      padding: const EdgeInsets.only(left: trafficLightInset, right: 8),
      child: Row(
        children: [
          _TitleIcon(
            icon: Icons.arrow_back_ios_new,
            tooltip: 'Back',
            onTap: () {},
            size: 12,
          ),
          _TitleIcon(
            icon: Icons.arrow_forward_ios,
            tooltip: 'Forward',
            onTap: () {},
            size: 12,
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: SizedBox(
                  height: 26,
                  child: TextField(
                    controller: _pathController,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: CursorColors.fg, fontSize: 12),
                    decoration: InputDecoration(
                      hintText: _rootPath != null
                          ? p.basename(_rootPath!)
                          : 'tryhard_ide',
                      hintStyle: TextStyle(
                        color: CursorColors.fgDim,
                        fontSize: 12,
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 14,
                        color: CursorColors.fgDim,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 26,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: CursorColors.input,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: CursorColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: CursorColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(color: CursorColors.accent),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    onSubmitted: (_) => _openFile(),
                  ),
                ),
              ),
            ),
          ),
          _TitleIcon(
            icon: Icons.folder_open,
            tooltip: 'Open folder',
            onTap: _pickFolder,
          ),
          _TitleIcon(
            icon: Icons.save_outlined,
            tooltip: _dirty ? 'Save (⌘S) — unsaved changes' : 'Save (⌘S)',
            onTap: _save,
            active: _dirty,
          ),
          ListenableBuilder(
            listenable: _runService,
            builder: (context, _) {
              final running = _runService.isRunning;
              return _TitleIcon(
                icon: running ? Icons.stop_circle_outlined : Icons.play_arrow,
                tooltip: running
                    ? 'Stop process'
                    : 'Run (⌘R) — open panel & start',
                onTap: _quickRun,
                active: running || _runOpen,
              );
            },
          ),
          _TitleIcon(
            icon: Icons.terminal,
            tooltip: _runOpen ? 'Hide run panel (⌘J)' : 'Show run panel (⌘J)',
            onTap: () => setState(() => _runOpen = !_runOpen),
            active: _runOpen,
          ),
          _TitleIcon(
            icon: Icons.copy_outlined,
            tooltip: 'Copy',
            onTap: () async {
              final text = _selection.isNotEmpty ? _selection : _editor.text;
              await Clipboard.setData(ClipboardData(text: text));
              _snack('Copied');
            },
          ),
          _TitleIcon(
            icon: Icons.chat_bubble_outline,
            tooltip: _chatOpen ? 'Hide chat' : 'Show chat',
            onTap: () => setState(() => _chatOpen = !_chatOpen),
            active: _chatOpen,
          ),
          Builder(
            builder: (context) {
              final theme = ThemeController.of(context);
              return _TitleIcon(
                icon: theme.isDark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                tooltip: theme.isDark ? 'Light theme' : 'Dark theme',
                onTap: theme.toggle,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tabBar() {
    final name = _fileName();
    final diffActive = _showEditorDiff &&
        _editorDiff?.path != null &&
        _openPath != null &&
        p.equals(_editorDiff!.path!, _openPath!);
    return Container(
      height: 35,
      color: CursorColors.tabInactive,
      child: Row(
        children: [
          if (name != null)
            Container(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
              height: 35,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: BoxDecoration(
                color: CursorColors.tabActive,
                border: Border(
                  top: BorderSide(
                    color: diffActive
                        ? const Color(0xFF7DFFB3)
                        : CursorColors.accent,
                    width: 1,
                  ),
                  right: BorderSide(color: CursorColors.border),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    diffActive ? Icons.compare_arrows : Icons.insert_drive_file_outlined,
                    size: 13,
                    color: diffActive
                        ? const Color(0xFF7DFFB3)
                        : CursorColors.fgMuted,
                  ),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      diffActive ? '$name (diff)' : name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: CursorColors.fgBright,
                        fontSize: 12,
                        fontStyle: _dirty ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),
                  ),
                  if (_editorDiff != null &&
                      _editorDiff!.ok &&
                      _openPath != null &&
                      p.equals(_editorDiff!.path!, _openPath!))
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: InkWell(
                        onTap: () => setState(() => _showEditorDiff = !_showEditorDiff),
                        child: Text(
                          diffActive ? 'CODE' : 'DIFF',
                          style: TextStyle(
                            color: diffActive
                                ? CursorColors.fgMuted
                                : const Color(0xFF7DFFB3),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  Tooltip(
                    message: _dirty ? 'Unsaved changes — Close' : 'Close',
                    child: InkWell(
                      onTap: _closeFile,
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: _dirty
                            ? Container(
                                width: 8,
                                height: 8,
                                margin: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  color: CursorColors.fgBright,
                                  shape: BoxShape.circle,
                                ),
                              )
                            : Icon(
                                Icons.close,
                                size: 14,
                                color: CursorColors.fgMuted,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          if (_openPath != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Text(
                _openPath!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: CursorColors.fgDim,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VerticalResizeHandle extends StatefulWidget {
  const _VerticalResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_VerticalResizeHandle> createState() => _VerticalResizeHandleState();
}

class _VerticalResizeHandleState extends State<_VerticalResizeHandle> {
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        onHorizontalDragStart: (_) => setState(() => _active = true),
        onHorizontalDragEnd: (_) => setState(() => _active = false),
        onHorizontalDragCancel: () => setState(() => _active = false),
        child: SizedBox(
          width: 5,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: 1,
              color: _active ? CursorColors.accent : CursorColors.border,
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleIcon extends StatelessWidget {
  const _TitleIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 15,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: size,
            color: active ? CursorColors.fgBright : CursorColors.fgMuted,
          ),
        ),
      ),
    );
  }
}
