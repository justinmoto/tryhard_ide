import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/apply_edit_result.dart';
import '../services/edit_proposal.dart';
import '../services/file_resolver.dart';
import '../services/ollama_service.dart';
import '../theme/cursor_theme.dart';
import 'diff_result_card.dart';

typedef ApplyEditCallback = Future<ApplyEditResult> Function(
  EditProposal proposal, {
  String? userPrompt,
});

class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.ollama,
    required this.rootPath,
    required this.openPath,
    required this.openFileName,
    required this.selection,
    required this.fileContent,
    required this.onClose,
    required this.applyEdit,
    required this.onOpenFile,
    this.onDiscardEdit,
    this.onKeepEdit,
  });

  final OllamaService ollama;
  final String? rootPath;
  final String? openPath;
  final String? openFileName;
  final String selection;
  final String fileContent;
  final VoidCallback onClose;
  final ApplyEditCallback applyEdit;
  final ValueChanged<String> onOpenFile;
  final Future<void> Function(ApplyEditResult result)? onDiscardEdit;
  final void Function(ApplyEditResult result)? onKeepEdit;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatEntry {
  _ChatEntry.text(this.message) : result = null;
  _ChatEntry.diff(this.result) : message = null;

  final ChatMessage? message;
  final ApplyEditResult? result;
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <_ChatEntry>[
    _ChatEntry.text(
      const ChatMessage(
        role: 'assistant',
        content:
            'Local AI ready. Open a project folder — I can find files (e.g. main.dart) and auto-apply edits with a red/green diff.',
      ),
    ),
  ];
  final _history = <ChatMessage>[];
  bool _sending = false;
  int _requestGen = 0;
  List<String> _projectFiles = const [];

  @override
  void initState() {
    super.initState();
    _loadProjectFiles();
  }

  @override
  void didUpdateWidget(covariant ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) {
      _loadProjectFiles();
    }
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
''';

  void _cancel() {
    if (!_sending) return;
    _requestGen++;
    widget.ollama.cancelChat();
    setState(() => _sending = false);
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
    final prompt = contextBlock.isEmpty
        ? text
        : '$text\n\n---\nProject context:\n$contextBlock';

    final gen = ++_requestGen;
    setState(() {
      _sending = true;
      _entries.add(_ChatEntry.text(ChatMessage(role: 'user', content: userVisible)));
      _history.add(ChatMessage(role: 'user', content: userVisible));
      _controller.clear();
    });

    try {
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

      setState(() {
        _history.add(ChatMessage(role: 'assistant', content: trimmed));
        _entries.add(_ChatEntry.text(ChatMessage(role: 'assistant', content: trimmed)));
      });

      if (proposal != null) {
        final result = await widget.applyEdit(proposal, userPrompt: text);
        if (!mounted || gen != _requestGen) return;
        setState(() {
          _entries.add(_ChatEntry.diff(result));
        });
      } else if (wantsEdit) {
        setState(() {
          _entries.add(
            _ChatEntry.text(
              const ChatMessage(
                role: 'assistant',
                content:
                    'No code block found to apply. Ask again and include the file name (e.g. lib/main.dart).',
              ),
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
                  _HeaderIcon(Icons.add, 'New chat', () {
                    setState(() {
                      _history.clear();
                      _entries
                        ..clear()
                        ..add(
                          _ChatEntry.text(
                            const ChatMessage(
                              role: 'assistant',
                              content: 'New chat. How can I help?',
                            ),
                          ),
                        );
                    });
                  }),
                  _HeaderIcon(Icons.view_sidebar_outlined, 'Close', widget.onClose),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: CursorColors.border),
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
                    child: SelectableText(
                      msg.content,
                      style: TextStyle(
                        color: CursorColors.fg,
                        fontSize: 13,
                        height: 1.4,
                      ),
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
