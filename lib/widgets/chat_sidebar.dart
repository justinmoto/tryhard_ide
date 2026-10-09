import 'package:flutter/material.dart';

import '../services/edit_proposal.dart';
import '../services/ollama_service.dart';
import '../theme/cursor_theme.dart';

typedef ApplyEditCallback = Future<bool> Function(EditProposal proposal);

class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.ollama,
    required this.openFileName,
    required this.selection,
    required this.fileContent,
    required this.onClose,
    required this.applyEdit,
  });

  final OllamaService ollama;
  final String? openFileName;
  final String selection;
  final String fileContent;
  final VoidCallback onClose;
  final ApplyEditCallback applyEdit;

  @override
  State<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends State<ChatSidebar> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <ChatMessage>[
    const ChatMessage(
      role: 'assistant',
      content:
          'Local AI ready. Open a file, select code, then ask me to change it — edits apply to the file automatically.',
    ),
  ];
  final _history = <ChatMessage>[];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _systemPrompt => '''
You are LocalForge, an on-device coding assistant that EDITS the open file.
The IDE auto-applies your code to the file.

When changing code, output the FULL updated file inside a fenced code block, e.g.:

```dart
// complete file contents here
```

Or for a small patch use:

<<<EDIT
exact old code from the file
===
new code
EDIT>>>

Rules:
- For "make me …", rewrite, or redesign requests: always return the complete file in a ```dart (or correct language) fence.
- Keep a one-line explanation outside the fence.
- If the user only asks a question, do not include a code fence.
- Never claim you need the internet.
''';

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    final contextBlock = StringBuffer();
    if (widget.openFileName != null) {
      contextBlock.writeln('Open file: ${widget.openFileName}');
    }
    if (widget.selection.trim().isNotEmpty) {
      contextBlock.writeln('Selection:\n```\n${widget.selection}\n```');
    } else if (widget.fileContent.trim().isNotEmpty) {
      final clipped = widget.fileContent.length > 6000
          ? '${widget.fileContent.substring(0, 6000)}\n…'
          : widget.fileContent;
      contextBlock.writeln('File contents:\n```\n$clipped\n```');
    }

    final userVisible = text;
    final prompt = contextBlock.isEmpty
        ? text
        : '$text\n\n---\nProject context:\n$contextBlock';

    setState(() {
      _sending = true;
      _messages.add(ChatMessage(role: 'user', content: userVisible));
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
      final trimmed = reply.trim();
      final wantsEdit = _looksLikeEditRequest(text);
      final proposal = EditProposal.parse(
        trimmed,
        fileContent: widget.fileContent,
        selection: widget.selection,
        // Auto-apply to whole file unless user highlighted a target.
        preferFileReplace:
            widget.selection.trim().isEmpty || wantsEdit,
      );

      setState(() {
        _history.add(ChatMessage(role: 'assistant', content: trimmed));
        _messages.add(ChatMessage(role: 'assistant', content: trimmed));
      });

      if (proposal != null) {
        final ok = await widget.applyEdit(proposal);
        if (!mounted) return;
        setState(() {
          _messages.add(
            ChatMessage(
              role: 'assistant',
              content: ok
                  ? '✓ Applied to the open file.'
                  : 'Could not apply edit. Open a text file first, then ask again.',
            ),
          );
        });
      } else if (_looksLikeEditRequest(text) && widget.openFileName != null) {
        setState(() {
          _messages.add(
            const ChatMessage(
              role: 'assistant',
              content:
                  'No editable block found. Try: select the code, then say exactly what to change (e.g. “rename greet to hello”).',
            ),
          );
        });
      }
    } catch (e) {
      setState(() {
        final err = ChatMessage(role: 'assistant', content: 'Error: $e');
        _history.add(err);
        _messages.add(err);
      });
    } finally {
      setState(() => _sending = false);
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
      'implement', 'improve', 'palitan', 'ayusin', 'gawin',
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
                      widget.openFileName ?? 'New Chat',
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
                      _messages
                        ..clear()
                        ..add(
                          const ChatMessage(
                            role: 'assistant',
                            content: 'New chat. How can I help?',
                          ),
                        );
                    });
                  }),
                  _HeaderIcon(Icons.history, 'History', () {}),
                  _HeaderIcon(Icons.more_horiz, 'More', () {}),
                  _HeaderIcon(Icons.view_sidebar_outlined, 'Close', widget.onClose),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: CursorColors.border),
          if (widget.selection.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: CursorColors.hover,
              child: Text(
                'Selection ready · AI edits can target it',
                style: TextStyle(color: CursorColors.fgMuted, fontSize: 11),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
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
                  TextField(
                    controller: _controller,
                    minLines: 2,
                    maxLines: 5,
                    style: TextStyle(color: CursorColors.fgBright, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Select code, then ask to change it…',
                      hintStyle: TextStyle(color: CursorColors.fgDim, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                    ),
                    onSubmitted: (_) => _send(),
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
                        InkWell(
                          onTap: _sending ? null : _send,
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: _sending
                                  ? CursorColors.hover
                                  : CursorColors.accent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: _sending
                                ? const Padding(
                                    padding: EdgeInsets.all(6),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.arrow_upward,
                                    size: 16,
                                    color: Colors.white,
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
