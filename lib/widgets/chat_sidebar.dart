import 'package:flutter/material.dart';

import '../services/ollama_service.dart';
import '../theme/cursor_theme.dart';

class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.ollama,
    required this.openFileName,
    required this.selection,
    required this.fileContent,
    required this.onClose,
  });

  final OllamaService ollama;
  final String? openFileName;
  final String selection;
  final String fileContent;
  final VoidCallback onClose;

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
          'Local AI chat ready. I can see the open file and selection. Ask anything — inference stays on this device.',
    ),
  ];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

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
      final clipped = widget.fileContent.length > 4000
          ? '${widget.fileContent.substring(0, 4000)}\n…'
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
      _controller.clear();
    });

    try {
      final history = <ChatMessage>[
        const ChatMessage(
          role: 'system',
          content:
              'You are LocalForge, an on-device coding assistant for web developers. Be concise and cite files when relevant. Never claim you need the internet.',
        ),
        for (final m in _messages)
          if (m.role == 'user' || m.role == 'assistant') m,
      ];
      if (history.isNotEmpty && history.last.role == 'user') {
        history[history.length - 1] = ChatMessage(role: 'user', content: prompt);
      }

      final reply = await widget.ollama.chat(messages: history);
      setState(() {
        _messages.add(ChatMessage(role: 'assistant', content: reply.trim()));
      });
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(role: 'assistant', content: 'Error: $e'));
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
                  SizedBox(width: 8),
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
                    style: TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Plan, search, build anything…',
                      hintStyle: TextStyle(color: CursorColors.fgDim, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.fromLTRB(12, 10, 12, 4),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.attach_file,
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
                        SizedBox(width: 8),
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
                                ? Padding(
                                    padding: EdgeInsets.all(6),
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : Icon(
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
