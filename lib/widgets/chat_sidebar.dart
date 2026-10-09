import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/apply_edit_result.dart';
import '../services/chat_history_store.dart';
import '../services/edit_proposal.dart';
import '../services/file_resolver.dart';
import '../services/ollama_service.dart';
import '../services/repo_index.dart';
import '../theme/cursor_theme.dart';
import 'diff_result_card.dart';
import 'themed_logo.dart';

typedef ApplyEditCallback = Future<ApplyEditResult> Function(
  EditProposal proposal, {
  String? userPrompt,
});

typedef OpenFileAtCallback = void Function(
  String path,
  int startLine,
  int endLine,
);

class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.ollama,
    required this.repoIndex,
    required this.rootPath,
    required this.openPath,
    required this.openFileName,
    required this.selection,
    required this.fileContent,
    required this.models,
    required this.onClose,
    required this.applyEdit,
    required this.onOpenFile,
    required this.onOpenFileAt,
    required this.onModelChanged,
    required this.onRefreshModels,
    this.onDiscardEdit,
    this.onKeepEdit,
  });

  final OllamaService ollama;
  final RepoIndex repoIndex;
  final String? rootPath;
  final String? openPath;
  final String? openFileName;
  final String selection;
  final String fileContent;
  final List<String> models;
  final VoidCallback onClose;
  final ApplyEditCallback applyEdit;
  final ValueChanged<String> onOpenFile;
  final OpenFileAtCallback onOpenFileAt;
  final ValueChanged<String> onModelChanged;
  final Future<void> Function() onRefreshModels;
  final Future<void> Function(ApplyEditResult result)? onDiscardEdit;
  final void Function(ApplyEditResult result)? onKeepEdit;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatEntry {
  _ChatEntry.text(
    this.message, {
    this.citations = const [],
    this.isNote = false,
    this.workDuration,
  }) : result = null;
  _ChatEntry.diff(this.result)
      : message = null,
        citations = const [],
        isNote = false,
        workDuration = null;

  final ChatMessage? message;
  final ApplyEditResult? result;

  /// Clickable `file:line` sources shown under an assistant answer.
  final List<CitationRef> citations;

  /// Shown in the chat but never sent to the model (status/info bubbles).
  final bool isNote;

  /// How long the model took (shown as "Worked for Xs").
  final Duration? workDuration;
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <_ChatEntry>[];
  final _history = <ChatMessage>[];

  bool get _isEmptyChat => _history.isEmpty && !_sending;
  bool _sending = false;
  String _statusLabel = '';
  DateTime? _statusStartedAt;
  int _requestGen = 0;
  List<String> _projectFiles = const [];

  /// Retrieve relevant repo chunks (RAG) for every question.
  bool _useRepo = true;
  List<ChatSession> _sessions = [];
  ChatSession _session = ChatSession.empty();
  int _sessionsGen = 0;

  /// Paths attached as prompt context (drag/drop or picker).
  final _attachments = <String>[];
  bool _dragOver = false;
  bool _pulling = false;
  String? _pullingModel;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechReady = false;
  bool _listening = false;
  String _voiceBase = '';

  static const _maxAttachBytes = 200 * 1024;
  static const _maxAttachChars = 12000;

  @override
  void initState() {
    super.initState();
    _loadProjectFiles();
    widget.repoIndex.open(widget.rootPath);
    _loadSessions();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    if (kIsWeb) return;
    try {
      final ok = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            setState(() => _listening = false);
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _listening = false);
          _entries.add(
            _ChatEntry.text(
              ChatMessage(
                role: 'assistant',
                content: 'Voice error: ${error.errorMsg}',
              ),
              isNote: true,
            ),
          );
        },
      );
      if (!mounted) return;
      setState(() => _speechReady = ok);
    } catch (_) {
      if (!mounted) return;
      setState(() => _speechReady = false);
    }
  }

  Future<void> _toggleVoice() async {
    if (kIsWeb) return;
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speechReady) {
      await _initSpeech();
      if (!_speechReady) {
        setState(() {
          _entries.add(
            _ChatEntry.text(
              const ChatMessage(
                role: 'assistant',
                content:
                    'Speech recognition unavailable. On macOS, grant Microphone '
                    'and Speech Recognition in System Settings, then restart the app '
                    '(first permission prompt may need a run from Xcode).',
              ),
              isNote: true,
            ),
          );
        });
        return;
      }
    }

    _voiceBase = _controller.text.trimRight();
    if (_voiceBase.isNotEmpty && !_voiceBase.endsWith(' ')) {
      _voiceBase = '$_voiceBase ';
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        final words = result.recognizedWords.trim();
        final next = '$_voiceBase$words';
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
        if (result.finalResult) {
          setState(() => _listening = false);
        } else {
          setState(() {});
        }
      },
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) {
      _loadProjectFiles();
      widget.repoIndex.open(widget.rootPath);
      _loadSessions();
    }
  }

  /// Restore the most recent chat for this workspace.
  Future<void> _loadSessions() async {
    final gen = ++_sessionsGen;
    final root = widget.rootPath;
    final sessions = await ChatHistoryStore.load(root);
    if (!mounted || gen != _sessionsGen) return;
    setState(() {
      _sessions = sessions;
      if (sessions.isNotEmpty) {
        _restoreSession(sessions.first);
      } else {
        _startNewSession();
      }
    });
  }

  void _restoreSession(ChatSession session) {
    _session = session;
    _history.clear();
    _entries.clear();
    for (final m in session.messages) {
      final msg = ChatMessage(role: m.role, content: m.content);
      _entries.add(
        _ChatEntry.text(msg, citations: m.citations, isNote: m.isNote),
      );
      if (!m.isNote) _history.add(msg);
    }
    _entries.insert(
      0,
      _ChatEntry.text(
        ChatMessage(
          role: 'assistant',
          content: 'Restored chat "${session.title}" '
              '(${_formatWhen(session.updatedAt)}).',
        ),
        isNote: true,
      ),
    );
    _scrollToEnd();
  }

  void _startNewSession() {
    _session = ChatSession.empty();
    _history.clear();
    _entries.clear();
  }

  /// Record a message in the current session and save to disk.
  Future<void> _remember(StoredChatMessage message) async {
    final session = _session;
    if (session.messages.isEmpty && message.role == 'user') {
      final firstLine = message.content.split('\n').first.trim();
      session.title = firstLine.length > 48
          ? '${firstLine.substring(0, 48)}…'
          : firstLine;
    }
    session.messages.add(message);
    session.updatedAt = DateTime.now();
    if (!_sessions.contains(session)) _sessions.insert(0, session);
    await ChatHistoryStore.save(widget.rootPath, _sessions);
  }

  Future<void> _deleteAllHistory() async {
    setState(() {
      _sessions = [];
      _startNewSession();
    });
    await ChatHistoryStore.save(widget.rootPath, _sessions);
  }

  static String _formatWhen(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _loadProjectFiles() async {
    final files = await FileResolver.listProjectFiles(widget.rootPath);
    if (!mounted) return;
    setState(() => _projectFiles = files);
  }

  @override
  void dispose() {
    _requestGen++;
    widget.ollama.cancelChat();
    if (_listening) {
      _speech.stop();
    }
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _systemPrompt => '''
You are Try Hard IDE, an on-device coding assistant. You edit project files; the IDE finds the file and applies your code automatically (file does not need to be open).

When changing code, ALWAYS:
1. Name the file on its own line: File: lib/main.dart
2. Output the FULL updated file in a fenced block tagged with the path:

```dart:lib/main.dart
// complete file contents
```

Rules:
- Prefer paths from the project file list when provided.
- For redesign / "make me …" requests, rewrite the whole target file.
- One short explanation, then File: line, then the code fence.
- If only answering a question, no code fence.
- Never claim you need the internet.

Repository questions:
- "Relevant code" excerpts from the repo may be provided, each line prefixed with its line number.
- Base answers on those excerpts and cite them inline as path:line or path:start-end (e.g. lib/main.dart:12-30).
- Only cite lines you were shown. If the excerpts don't contain the answer, say so.
''';

  void _cancel() {
    if (!_sending) return;
    _requestGen++;
    widget.ollama.cancelChat();
    widget.repoIndex.cancel();
    setState(() {
      _sending = false;
      _statusLabel = '';
      _statusStartedAt = null;
    });
  }

  void _setStatus(String label) {
    if (!mounted) return;
    setState(() => _statusLabel = label);
    _scrollToEnd();
  }

  static String _formatDuration(Duration d) {
    if (d.inMinutes >= 1) {
      final s = d.inSeconds % 60;
      return '${d.inMinutes}m ${s}s';
    }
    return '${d.inSeconds.clamp(1, 999)}s';
  }

  String _shortModelName(String name) {
    final colon = name.indexOf(':');
    if (colon <= 0) {
      return name.length > 14 ? '${name.substring(0, 12)}…' : name;
    }
    final base = name.substring(0, colon);
    final tag = name.substring(colon + 1);
    if (tag == 'latest') {
      return base.length > 14 ? '${base.substring(0, 12)}…' : base;
    }
    // e.g. qwen2.5-coder:3b -> qwen…:3b
    if (name.length <= 12) return name;
    final keepBase = (10 - tag.length).clamp(3, 8);
    final shortBase = base.length > keepBase
        ? '${base.substring(0, keepBase)}…'
        : base;
    return '$shortBase:$tag';
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  String _displayPath(String path) {
    final root = widget.rootPath;
    if (root != null && p.isWithin(root, path)) {
      return p.relative(path, from: root);
    }
    return p.basename(path);
  }

  Future<void> _attachPaths(Iterable<String> paths) async {
    final added = <String>[];
    for (final raw in paths) {
      final path = raw.trim();
      if (path.isEmpty) continue;
      if (_attachments.contains(path)) continue;
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.file) continue;
      added.add(path);
    }
    if (added.isEmpty || !mounted) return;
    setState(() => _attachments.addAll(added));
  }

  void _removeAttachment(String path) {
    setState(() => _attachments.remove(path));
  }

  Future<void> _pickAttachments() async {
    if (kIsWeb) return;
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      dialogTitle: 'Attach files to chat',
    );
    if (result == null) return;
    await _attachPaths([
      for (final f in result.files)
        if (f.path != null) f.path!,
    ]);
  }

  Future<void> _pullModel(String name) async {
    if (_pulling) return;
    setState(() {
      _pulling = true;
      _pullingModel = name;
      _entries.add(
        _ChatEntry.text(
          ChatMessage(
            role: 'assistant',
            content: 'Downloading $name…',
          ),
          isNote: true,
        ),
      );
    });
    _scrollToEnd();
    try {
      await widget.ollama.pullModel(
        name,
        onProgress: (status, progress) {
          if (!mounted) return;
          final pct = progress == null ? '' : ' ${(progress * 100).round()}%';
          setState(() {
            if (_entries.isNotEmpty && _entries.last.isNote) {
              _entries[_entries.length - 1] = _ChatEntry.text(
                ChatMessage(
                  role: 'assistant',
                  content: 'Downloading $name — $status$pct',
                ),
                isNote: true,
              );
            }
          });
        },
      );
      await widget.onRefreshModels();
      if (!mounted) return;
      widget.onModelChanged(name);
      setState(() {
        _entries.add(
          _ChatEntry.text(
            ChatMessage(
              role: 'assistant',
              content: 'Ready — switched to $name.',
            ),
            isNote: true,
          ),
        );
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _entries.add(
          _ChatEntry.text(
            ChatMessage(role: 'assistant', content: 'Pull failed: $e'),
            isNote: true,
          ),
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _pulling = false;
          _pullingModel = null;
        });
      }
    }
  }

  Future<String> _readAttachment(String path) async {
    try {
      final file = File(path);
      final len = await file.length();
      if (len > _maxAttachBytes) {
        return '(file too large to attach: ${(len / 1024).round()} KB)';
      }
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) return '(binary file — contents omitted)';
      var text = String.fromCharCodes(bytes);
      if (text.length > _maxAttachChars) {
        text = '${text.substring(0, _maxAttachChars)}\n…';
      }
      return text;
    } catch (e) {
      return '(could not read file: $e)';
    }
  }

  /// Refresh the index (only changed files) and fetch chunks for [query].
  Future<List<RetrievedChunk>> _retrieve(String query) async {
    final index = widget.repoIndex;
    if (!_useRepo || widget.rootPath == null) return const [];
    if (!index.busy) await index.build();
    return index.search(query, k: 6);
  }

  static String _formatChunks(List<RetrievedChunk> chunks) {
    final b = StringBuffer();
    for (final r in chunks) {
      final c = r.chunk;
      b.writeln('[${c.label}]');
      b.writeln('```');
      final lines = c.text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        b.writeln('${c.startLine + i}| ${lines[i]}');
      }
      b.writeln('```');
    }
    return b.toString();
  }

  void _openCitation(CitationRef ref) {
    final index = widget.repoIndex;
    if (index.rootPath == null) return;
    widget.onOpenFileAt(
      index.absolutePath(ref.path),
      ref.startLine,
      ref.endLine,
    );
  }

  Future<void> _send() async {
    final raw = _controller.text.trim();
    if ((raw.isEmpty && _attachments.isEmpty) || _sending) return;
    final text = raw.isEmpty ? 'Please review the attached file(s).' : raw;

    final status = await widget.ollama.checkStatus();
    if (!mounted) return;
    if (!status.online) {
      setState(() {
        _entries.add(
          _ChatEntry.text(
            ChatMessage(
              role: 'assistant',
              content:
                  'Ollama is offline${status.error != null ? ': ${status.error}' : ''}. Start it, then try again.',
            ),
          ),
        );
      });
      return;
    }
    if (status.models.isEmpty) {
      setState(() {
        _entries.add(
          _ChatEntry.text(
            ChatMessage(
              role: 'assistant',
              content:
                  'No Ollama models installed. In a terminal run:\n\nollama pull ${widget.ollama.chatModel}',
            ),
          ),
        );
      });
      return;
    }
    if (!status.models.contains(widget.ollama.chatModel)) {
      setState(() {
        _entries.add(
          _ChatEntry.text(
            ChatMessage(
              role: 'assistant',
              content:
                  'Model "${widget.ollama.chatModel}" is not installed. '
                  'Pick one from the status bar, or run:\n\n'
                  'ollama pull ${widget.ollama.chatModel}\n\n'
                  'Available: ${status.models.join(', ')}',
            ),
          ),
        );
      });
      return;
    }

    final contextBlock = StringBuffer();
    if (widget.rootPath != null) {
      contextBlock.writeln('Project root: ${widget.rootPath}');
    }
    if (_projectFiles.isNotEmpty) {
      contextBlock.writeln('Project files:');
      for (final f in _projectFiles.take(30)) {
        contextBlock.writeln('- $f');
      }
    }
    if (widget.openPath != null) {
      contextBlock.writeln('Currently open: ${widget.openPath}');
    }
    if (widget.selection.trim().isNotEmpty) {
      contextBlock.writeln('Selection:\n```\n${widget.selection}\n```');
    } else if (widget.fileContent.trim().isNotEmpty && widget.openPath != null) {
      final clipped = widget.fileContent.length > 5000
          ? '${widget.fileContent.substring(0, 5000)}\n…'
          : widget.fileContent;
      contextBlock.writeln('Open file contents:\n```\n$clipped\n```');
    }

    final attachedPaths = List<String>.from(_attachments);
    final attachLabels = [
      for (final path in attachedPaths) _displayPath(path),
    ];
    final userVisible = attachLabels.isEmpty
        ? text
        : '$text\n\n${attachLabels.map((f) => '📎 $f').join('\n')}';

    final gen = ++_requestGen;
    final started = DateTime.now();
    setState(() {
      _sending = true;
      _statusStartedAt = started;
      _statusLabel = _useRepo && widget.rootPath != null
          ? 'Searching project…'
          : 'Thinking…';
      _entries.add(_ChatEntry.text(ChatMessage(role: 'user', content: userVisible)));
      _history.add(ChatMessage(role: 'user', content: userVisible));
      _controller.clear();
      _attachments.clear();
    });
    _scrollToEnd();
    _remember(StoredChatMessage(role: 'user', content: userVisible));

    try {
      if (attachedPaths.isNotEmpty) {
        _setStatus('Reading attachments…');
        contextBlock.writeln('Attached files (treat as primary context):');
        for (final path in attachedPaths) {
          final label = _displayPath(path);
          final body = await _readAttachment(path);
          if (!mounted || gen != _requestGen) return;
          contextBlock
            ..writeln()
            ..writeln('File: $label')
            ..writeln('```')
            ..writeln(body)
            ..writeln('```');
        }
      }

      final retrieved = await _retrieve(text);
      if (!mounted || gen != _requestGen) return;
      if (retrieved.isNotEmpty) {
        contextBlock
          ..writeln()
          ..writeln('Relevant code (cite as path:line):')
          ..write(_formatChunks(retrieved));
      }
      final prompt = contextBlock.isEmpty
          ? text
          : '$text\n\n---\nProject context:\n$contextBlock';

      final messages = <ChatMessage>[
        ChatMessage(role: 'system', content: _systemPrompt),
        ..._history.take(_history.length - 1),
        ChatMessage(role: 'user', content: prompt),
      ];

      _setStatus('Thinking…');
      final reply = await widget.ollama.chat(messages: messages);
      if (!mounted || gen != _requestGen) return;

      final trimmed = reply.trim();
      final wantsEdit = _looksLikeEditRequest(text);
      final proposal = EditProposal.parse(
        trimmed,
        fileContent: widget.fileContent,
        selection: widget.selection,
        preferFileReplace: widget.selection.trim().isEmpty || wantsEdit,
      );

      // Prefer what the model actually cited; otherwise list what it was given.
      var citations = widget.repoIndex.parseCitations(trimmed);
      if (citations.isEmpty && proposal == null) {
        citations = [
          for (final r in retrieved)
            CitationRef(
              path: r.chunk.path,
              startLine: r.chunk.startLine,
              endLine: r.chunk.endLine,
            ),
        ];
      }

      final workDuration = DateTime.now().difference(started);
      setState(() {
        _history.add(ChatMessage(role: 'assistant', content: trimmed));
        _entries.add(
          _ChatEntry.text(
            ChatMessage(role: 'assistant', content: trimmed),
            citations: citations,
            workDuration: workDuration,
          ),
        );
        if (proposal != null) {
          _statusLabel = 'Applying edit…';
        }
      });
      _scrollToEnd();
      _remember(
        StoredChatMessage(
          role: 'assistant',
          content: trimmed,
          citations: citations,
        ),
      );

      if (proposal != null) {
        final result = await widget.applyEdit(proposal, userPrompt: text);
        if (!mounted || gen != _requestGen) return;
        setState(() {
          _entries.add(_ChatEntry.diff(result));
        });
        _remember(
          StoredChatMessage(
            role: 'assistant',
            content: result.ok
                ? 'Applied edit to ${result.path}'
                : 'Edit failed: ${result.error}',
            isNote: true,
          ),
        );
      } else if (wantsEdit) {
        setState(() {
          _entries.add(
            _ChatEntry.text(
              const ChatMessage(
                role: 'assistant',
                content:
                    'No code block found to apply. Ask again and include the file name (e.g. lib/main.dart).',
              ),
              isNote: true,
            ),
          );
        });
      }
    } on ChatCancelledException {
      // Stopped by user — keep the user message, no error bubble.
    } catch (e) {
      if (!mounted || gen != _requestGen) return;
      setState(() {
        final err = ChatMessage(role: 'assistant', content: 'Error: $e');
        _history.add(err);
        _entries.add(
          _ChatEntry.text(
            err,
            workDuration: DateTime.now().difference(started),
          ),
        );
      });
    } finally {
      if (mounted && gen == _requestGen) {
        setState(() {
          _sending = false;
          _statusLabel = '';
          _statusStartedAt = null;
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  Widget _historyMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Chat history',
      color: CursorColors.panel,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
      onSelected: (id) {
        if (id == '__clear__') {
          _deleteAllHistory();
          return;
        }
        final session = _sessions.where((s) => s.id == id).firstOrNull;
        if (session == null) return;
        if (_sending) _cancel();
        setState(() => _restoreSession(session));
      },
      itemBuilder: (context) {
        final saved = _sessions.where((s) => s.messages.isNotEmpty).toList();
        if (saved.isEmpty) {
          return [
            PopupMenuItem<String>(
              enabled: false,
              child: Text(
                'No saved chats for this folder yet',
                style: TextStyle(color: CursorColors.fgDim, fontSize: 12),
              ),
            ),
          ];
        }
        return [
          for (final s in saved)
            PopupMenuItem<String>(
              value: s.id,
              height: 40,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: s.id == _session.id
                          ? CursorColors.fgBright
                          : CursorColors.fg,
                      fontSize: 12,
                      fontWeight: s.id == _session.id
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                  Text(
                    '${_formatWhen(s.updatedAt)} · ${s.messages.where((m) => !m.isNote).length} messages',
                    style: TextStyle(color: CursorColors.fgDim, fontSize: 10),
                  ),
                ],
              ),
            ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: '__clear__',
            height: 32,
            child: Text(
              'Clear chat history',
              style: TextStyle(color: CursorColors.statusOffline, fontSize: 12),
            ),
          ),
        ];
      },
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Icon(Icons.history, size: 15, color: CursorColors.fgMuted),
      ),
    );
  }

  Widget _indexBar() {
    return ListenableBuilder(
      listenable: widget.repoIndex,
      builder: (context, _) {
        final index = widget.repoIndex;
        final progress = index.busy && index.progressTotal > 0
            ? index.progressDone / index.progressTotal
            : null;
        final warning = index.embedError;
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: CursorColors.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    index.hasVectors ? Icons.hub_outlined : Icons.manage_search,
                    size: 13,
                    color: CursorColors.fgMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Repo index: ${index.status}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
                    ),
                  ),
                  if (index.busy)
                    _HeaderIcon(Icons.stop_circle_outlined, 'Stop indexing', index.cancel)
                  else ...[
                    _HeaderIcon(
                      Icons.sync,
                      index.isEmpty ? 'Index repo' : 'Update index (changed files)',
                      () => index.build(),
                    ),
                    if (!index.isEmpty)
                      _HeaderIcon(
                        Icons.restart_alt,
                        'Rebuild index from scratch',
                        () => index.build(force: true),
                      ),
                  ],
                ],
              ),
              if (index.busy) ...[
                const SizedBox(height: 3),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  backgroundColor: CursorColors.border,
                  color: CursorColors.accent,
                ),
              ],
              if (warning != null && !index.busy)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Keyword search only — $warning',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: CursorColors.fgDim, fontSize: 10),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  bool _looksLikeEditRequest(String text) {
    final t = text.toLowerCase();
    const keys = [
      'change', 'fix', 'rename', 'refactor', 'rewrite', 'replace',
      'update', 'add', 'remove', 'delete', 'edit', 'make', 'convert',
      'implement', 'improve', 'palitan', 'ayusin', 'gawin', 'dashboard',
      'create', 'build',
    ];
    return keys.any(t.contains);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: CursorColors.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 38,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _session.title.isEmpty || _session.messages.isEmpty
                          ? (widget.openFileName ?? 'New chat')
                          : _session.title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: CursorColors.fgBright,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _HeaderIcon(Icons.add, 'New chat', () {
                    if (_sending) _cancel();
                    setState(_startNewSession);
                  }),
                  _historyMenu(),
                  _HeaderIcon(Icons.view_sidebar_outlined, 'Close', widget.onClose),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: CursorColors.border),
          if (widget.rootPath != null) _indexBar(),
          if (widget.rootPath == null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: const Color(0xFF3A2A1A),
              child: Text(
                'Open a project folder so I can find files to edit',
                style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
              ),
            )
          else if (widget.selection.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: CursorColors.hover,
              child: Text(
                'Selection ready · edits can target it',
                style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
              ),
            ),
          if (_isEmptyChat)
            Expanded(child: _emptyChat())
          else ...[
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                itemCount: _entries.length + (_sending ? 1 : 0),
                itemBuilder: (context, index) {
                  if (_sending && index == _entries.length) {
                    return _StatusLine(
                      label: _statusLabel.isEmpty ? 'Thinking…' : _statusLabel,
                      loading: true,
                      startedAt: _statusStartedAt,
                      formatDuration: _formatDuration,
                    );
                  }
                  final entry = _entries[index];
                  if (entry.result != null) {
                    final r = entry.result!;
                    return DiffResultCard(
                      result: r,
                      onOpen: widget.onOpenFile,
                      onDiscard: r.ok && widget.onDiscardEdit != null
                          ? () => widget.onDiscardEdit!(r)
                          : null,
                      onKeep: r.ok && widget.onKeepEdit != null
                          ? () => widget.onKeepEdit!(r)
                          : null,
                    );
                  }
                  return _MessageBlock(
                    entry: entry,
                    onOpenCitation: _openCitation,
                    onCopy: () => _copyText(entry.message!.content),
                    formatDuration: _formatDuration,
                  );
                },
              ),
            ),
            if (widget.rootPath != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                child: Row(
                  children: [
                    Icon(Icons.chevron_right, size: 14, color: CursorColors.fgDim),
                    Text(
                      '${_projectFiles.length} Files',
                      style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
                    ),
                    const Spacer(),
                    if (widget.selection.trim().isNotEmpty)
                      Text(
                        'Selection · ready',
                        style: TextStyle(color: CursorColors.fgDim, fontSize: 11),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _buildComposer(minLines: 2, maxLines: 6),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyChat() {
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildComposer(minLines: 3, maxLines: 8, emptyStyle: true),
            const SizedBox(height: 28),
            Center(
              child: Column(
                children: [
                  const ThemedLogo(size: 56),
                  const SizedBox(height: 10),
                  Text(
                    'Try Hard IDE',
                    style: TextStyle(
                      color: CursorColors.fgMuted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.rootPath == null
                        ? 'Open a folder, then plan and build locally'
                        : 'Plan, search, and edit this project',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: CursorColors.fgDim, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer({
    int minLines = 2,
    int maxLines = 6,
    bool emptyStyle = false,
  }) {
    final highlight = _dragOver;
    final box = Container(
      decoration: BoxDecoration(
        color: highlight
            ? CursorColors.accent.withValues(alpha: 0.08)
            : CursorColors.input,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight ? CursorColors.accent : CursorColors.border,
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final path in _attachments)
                    _AttachmentChip(
                      label: _displayPath(path),
                      onRemove: () => _removeAttachment(path),
                    ),
                ],
              ),
            ),
          Focus(
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final isEnter =
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.numpadEnter;
              if (!isEnter) return KeyEventResult.ignored;
              if (HardwareKeyboard.instance.isShiftPressed) {
                return KeyEventResult.ignored;
              }
              _send();
              return KeyEventResult.handled;
            },
            child: TextField(
              controller: _controller,
              autofocus: emptyStyle,
              minLines: minLines,
              maxLines: maxLines,
              textInputAction: TextInputAction.newline,
              style: TextStyle(
                color: CursorColors.fgBright,
                fontSize: 13,
                height: 1.4,
              ),
              decoration: InputDecoration(
                hintText: _listening
                    ? 'Listening… speak your prompt'
                    : highlight
                        ? 'Drop files to attach as context…'
                        : 'Ask — edit files, explain code, ship ideas…',
                hintStyle: TextStyle(
                  color: CursorColors.fgDim,
                  fontSize: 13,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                _ModePill(
                  icon: Icons.code,
                  selected: _useRepo,
                  onTap: () => setState(() => _useRepo = !_useRepo),
                  tooltip: _useRepo
                      ? 'Repo context on — retrieve and apply edits'
                      : 'Repo context off',
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: _ModelPicker(
                    model: widget.ollama.chatModel,
                    models: widget.models,
                    shortName: _shortModelName,
                    onChanged: widget.onModelChanged,
                    onPull: _pulling ? null : _pullModel,
                    pullingModel: _pullingModel,
                    asText: true,
                  ),
                ),
                Tooltip(
                  message: 'Attach files',
                  child: InkWell(
                    onTap: kIsWeb ? null : _pickAttachments,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Icon(
                        Icons.attach_file,
                        size: 16,
                        color: CursorColors.fgMuted,
                      ),
                    ),
                  ),
                ),
                Tooltip(
                  message: _listening ? 'Stop listening' : 'Voice input',
                  child: InkWell(
                    onTap: kIsWeb || _sending ? null : _toggleVoice,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _listening
                            ? CursorColors.statusOffline.withValues(alpha: 0.2)
                            : CursorColors.hover,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _listening
                              ? CursorColors.statusOffline
                              : CursorColors.border,
                        ),
                      ),
                      child: Icon(
                        _listening ? Icons.mic : Icons.mic_none_outlined,
                        size: 15,
                        color: _listening
                            ? CursorColors.statusOffline
                            : CursorColors.fgMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Tooltip(
                  message: _sending ? 'Stop' : 'Send',
                  child: InkWell(
                    onTap: _sending ? _cancel : _send,
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _sending
                            ? CursorColors.fgMuted
                            : CursorColors.fgBright,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _sending
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                        size: 15,
                        color: CursorColors.sidebar,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragOver = true),
      onDragExited: (_) => setState(() => _dragOver = false),
      onDragDone: (detail) async {
        setState(() => _dragOver = false);
        await _attachPaths([for (final f in detail.files) f.path]);
      },
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          setState(() => _dragOver = true);
          return true;
        },
        onLeave: (_) => setState(() => _dragOver = false),
        onAcceptWithDetails: (details) {
          setState(() => _dragOver = false);
          _attachPaths([details.data]);
        },
        builder: (context, candidate, rejected) => box,
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.only(left: 8, right: 2, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: CursorColors.hover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CursorColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 12, color: CursorColors.fgMuted),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: CursorColors.fg, fontSize: 11),
            ),
          ),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.close, size: 13, color: CursorColors.fgDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBlock extends StatelessWidget {
  const _MessageBlock({
    required this.entry,
    required this.onOpenCitation,
    required this.onCopy,
    required this.formatDuration,
  });

  final _ChatEntry entry;
  final ValueChanged<CitationRef> onOpenCitation;
  final VoidCallback onCopy;
  final String Function(Duration) formatDuration;

  @override
  Widget build(BuildContext context) {
    final msg = entry.message!;
    final isUser = msg.role == 'user';

    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: CursorColors.chatUser,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: CursorColors.border),
            ),
            child: SelectableText(
              msg.content,
              style: TextStyle(
                color: CursorColors.fgBright,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry.workDuration != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Worked for ${formatDuration(entry.workDuration!)}',
                style: TextStyle(
                  color: CursorColors.fgDim,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          SelectableText(
            msg.content,
            style: TextStyle(
              color: CursorColors.fg,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (entry.citations.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final c in entry.citations)
                  _CitationChip(
                    label: c.label,
                    onTap: () => onOpenCitation(c),
                  ),
              ],
            ),
          ],
          if (!entry.isNote) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _ActionIcon(
                  icon: Icons.copy_outlined,
                  tooltip: 'Copy',
                  onTap: onCopy,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusLine extends StatefulWidget {
  const _StatusLine({
    required this.label,
    this.loading = false,
    this.startedAt,
    this.formatDuration,
  });

  final String label;
  final bool loading;
  final DateTime? startedAt;
  final String Function(Duration)? formatDuration;

  @override
  State<_StatusLine> createState() => _StatusLineState();
}

class _StatusLineState extends State<_StatusLine> {
  late final ticker = Stream.periodic(const Duration(seconds: 1));

  @override
  Widget build(BuildContext context) {
    final started = widget.startedAt;
    final format = widget.formatDuration;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 2),
      child: Row(
        children: [
          if (widget.loading) ...[
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: CursorColors.fgDim,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: started != null && format != null
                ? StreamBuilder(
                    stream: ticker,
                    builder: (context, _) {
                      final elapsed = DateTime.now().difference(started);
                      return Text(
                        '${widget.label} · ${format(elapsed)}',
                        style: TextStyle(
                          color: CursorColors.fgDim,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      );
                    },
                  )
                : Text(
                    widget.label,
                    style: TextStyle(
                      color: CursorColors.fgDim,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.model,
    required this.models,
    required this.shortName,
    required this.onChanged,
    this.onPull,
    this.pullingModel,
    this.asText = false,
  });

  final String model;
  final List<String> models;
  final String Function(String) shortName;
  final ValueChanged<String> onChanged;
  final Future<void> Function(String name)? onPull;
  final String? pullingModel;
  final bool asText;

  @override
  Widget build(BuildContext context) {
    final installed = models.toSet();
    final catalog = OllamaService.catalog(models);
    final label = models.isEmpty
        ? (pullingModel != null ? 'Pulling…' : 'Add model')
        : shortName(model);
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!asText) ...[
          Icon(Icons.auto_awesome, size: 13, color: CursorColors.fgMuted),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: CursorColors.fg,
              fontSize: asText ? 12 : 11,
              fontWeight: asText ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
        ),
        Icon(Icons.expand_more, size: 14, color: CursorColors.fgDim),
      ],
    );

    return PopupMenuButton<String>(
      tooltip: models.isEmpty ? 'Model' : model,
      onSelected: (value) {
        if (value.startsWith('pull:')) {
          onPull?.call(value.substring(5));
          return;
        }
        onChanged(value);
      },
      color: CursorColors.panel,
      offset: const Offset(0, -8),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[
          PopupMenuItem(
            enabled: false,
            height: 28,
            child: Text(
              'Installed',
              style: TextStyle(color: CursorColors.fgDim, fontSize: 10),
            ),
          ),
        ];
        final ready = catalog.where(installed.contains).toList();
        if (ready.isEmpty) {
          items.add(
            PopupMenuItem(
              enabled: false,
              height: 32,
              child: Text(
                'None yet — pull one below',
                style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
              ),
            ),
          );
        } else {
          for (final name in ready) {
            items.add(
              PopupMenuItem(
                value: name,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          color: name == model
                              ? CursorColors.fgBright
                              : CursorColors.fg,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (name == model)
                      Icon(Icons.check, size: 14, color: CursorColors.accent),
                  ],
                ),
              ),
            );
          }
        }

        final missing = catalog.where((m) => !installed.contains(m)).toList();
        if (missing.isNotEmpty && onPull != null) {
          items
            ..add(const PopupMenuDivider())
            ..add(
              PopupMenuItem(
                enabled: false,
                height: 28,
                child: Text(
                  'Download',
                  style: TextStyle(color: CursorColors.fgDim, fontSize: 10),
                ),
              ),
            );
          for (final name in missing) {
            final busy = pullingModel == name;
            items.add(
              PopupMenuItem(
                value: 'pull:$name',
                enabled: !busy && pullingModel == null,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          color: CursorColors.fgMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      busy ? '…' : 'Pull',
                      style: TextStyle(
                        color: CursorColors.accentSoft,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        }
        return items;
      },
      child: asText
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 100),
                child: child,
              ),
            )
          : _Pill(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: child,
              ),
            ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: _Pill(
          child: Icon(
            icon,
            size: 15,
            color: selected ? CursorColors.fgBright : CursorColors.fgMuted,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: CursorColors.hover,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CursorColors.border),
      ),
      child: child,
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: CursorColors.fgDim),
        ),
      ),
    );
  }
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Open $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: CursorColors.input,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: CursorColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.description_outlined, size: 11, color: CursorColors.accentSoft),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: CursorColors.accentSoft,
                    fontSize: 11,
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon(this.icon, this.tooltip, this.onTap);

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 15, color: CursorColors.fgMuted),
        ),
      ),
    );
  }
}
