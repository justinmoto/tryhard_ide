import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/apply_edit_result.dart';
import '../services/chat_history_store.dart';
import '../services/edit_proposal.dart';
import '../services/file_resolver.dart';
import '../services/ollama_service.dart';
import '../services/repo_index.dart';
import '../theme/cursor_theme.dart';
import 'diff_result_card.dart';

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
    required this.onClose,
    required this.applyEdit,
    required this.onOpenFile,
    required this.onOpenFileAt,
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
  final VoidCallback onClose;
  final ApplyEditCallback applyEdit;
  final ValueChanged<String> onOpenFile;
  final OpenFileAtCallback onOpenFileAt;
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
  }) : result = null;
  _ChatEntry.diff(this.result)
      : message = null,
        citations = const [],
        isNote = false;

  final ChatMessage? message;
  final ApplyEditResult? result;

  /// Clickable `file:line` sources shown under an assistant answer.
  final List<CitationRef> citations;

  /// Shown in the chat but never sent to the model (status/info bubbles).
  final bool isNote;
}

class _ChatSidebarState extends State<ChatSidebar> {
  static const _welcome =
      'Local AI ready. Open a project folder — I can find files (e.g. main.dart), '
      'answer questions about the repo with file:line sources, and auto-apply '
      'edits with a red/green diff.';

  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <_ChatEntry>[
    _ChatEntry.text(
      const ChatMessage(role: 'assistant', content: _welcome),
      isNote: true,
    ),
  ];
  final _history = <ChatMessage>[];
  bool _sending = false;
  int _requestGen = 0;
  List<String> _projectFiles = const [];

  /// Retrieve relevant repo chunks (RAG) for every question.
  bool _useRepo = true;
  List<ChatSession> _sessions = [];
  ChatSession _session = ChatSession.empty();
  int _sessionsGen = 0;

  @override
  void initState() {
    super.initState();
    _loadProjectFiles();
    widget.repoIndex.open(widget.rootPath);
    _loadSessions();
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
        _startNewSession(greeting: _welcome);
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

  void _startNewSession({String greeting = 'New chat. How can I help?'}) {
    _session = ChatSession.empty();
    _history.clear();
    _entries
      ..clear()
      ..add(
        _ChatEntry.text(
          ChatMessage(role: 'assistant', content: greeting),
          isNote: true,
        ),
      );
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
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _systemPrompt => '''
You are LocalForge, an on-device coding assistant. You edit project files; the IDE finds the file and applies your code automatically (file does not need to be open).

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
    setState(() => _sending = false);
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
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

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

    final userVisible = text;

    final gen = ++_requestGen;
    setState(() {
      _sending = true;
      _entries.add(_ChatEntry.text(ChatMessage(role: 'user', content: userVisible)));
      _history.add(ChatMessage(role: 'user', content: userVisible));
      _controller.clear();
    });
    _remember(StoredChatMessage(role: 'user', content: userVisible));

    try {
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

      setState(() {
        _history.add(ChatMessage(role: 'assistant', content: trimmed));
        _entries.add(
          _ChatEntry.text(
            ChatMessage(role: 'assistant', content: trimmed),
            citations: citations,
          ),
        );
      });
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
        _entries.add(_ChatEntry.text(err));
      });
    } finally {
      if (mounted && gen == _requestGen) {
        setState(() => _sending = false);
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
            height: 35,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(Icons.flag_outlined, size: 14, color: CursorColors.fgMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.openFileName ?? 'AI Edits',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: CursorColors.fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  _historyMenu(),
                  _HeaderIcon(Icons.add, 'New chat', () {
                    if (_sending) _cancel();
                    setState(_startNewSession);
                  }),
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
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              itemCount: _entries.length,
              itemBuilder: (context, index) {
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
                final msg = entry.message!;
                final isUser = msg.role == 'user';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    constraints: const BoxConstraints(maxWidth: 340),
                    decoration: BoxDecoration(
                      color: isUser
                          ? CursorColors.chatUser
                          : CursorColors.hover,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CursorColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SelectableText(
                          msg.content,
                          style: TextStyle(
                            color: CursorColors.fg,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        if (entry.citations.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Sources',
                            style: TextStyle(
                              color: CursorColors.fgDim,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final c in entry.citations)
                                _CitationChip(
                                  label: c.label,
                                  onTap: () => _openCitation(c),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Container(
              decoration: BoxDecoration(
                color: CursorColors.input,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: CursorColors.border),
              ),
              child: Column(
                children: [
                  Focus(
                    onKeyEvent: (node, event) {
                      if (event is! KeyDownEvent) {
                        return KeyEventResult.ignored;
                      }
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
                      minLines: 2,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        color: CursorColors.fgBright,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        hintText:
                            'e.g. rewrite lib/main.dart as a cafe dashboard…',
                        hintStyle: TextStyle(
                          color: CursorColors.fgDim,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.fromLTRB(12, 10, 12, 4),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_fix_high,
                          size: 16,
                          color: CursorColors.fgMuted,
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: _useRepo
                              ? 'Repo context on: relevant code is retrieved and cited'
                              : 'Repo context off',
                          child: InkWell(
                            onTap: () => setState(() => _useRepo = !_useRepo),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _useRepo
                                    ? CursorColors.accent.withValues(alpha: 0.18)
                                    : null,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: _useRepo
                                      ? CursorColors.accent
                                      : CursorColors.border,
                                ),
                              ),
                              child: Text(
                                '@repo',
                                style: TextStyle(
                                  color: _useRepo
                                      ? CursorColors.fgBright
                                      : CursorColors.fgDim,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          widget.ollama.chatModel,
                          style: TextStyle(
                            color: CursorColors.fgDim,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: _sending ? 'Stop' : 'Send',
                          child: InkWell(
                            onTap: _sending ? _cancel : _send,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: CursorColors.accent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                _sending ? Icons.stop_rounded : Icons.arrow_upward,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
