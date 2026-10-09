import 'package:flutter/material.dart';

import '../services/ollama_service.dart';

class ChatSidebar extends StatefulWidget {
  const ChatSidebar({
    super.key,
    required this.ollama,
    required this.openFileName,
    required this.selection,
    required this.fileContent,
  });

  final OllamaService ollama;
  final String? openFileName;
  final String selection;
  final String fileContent;

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
      // Replace last user message with contextual prompt for the model.
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
      color: const Color(0xFF151821),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Row(
              children: [
                const Icon(Icons.smart_toy_outlined, color: Color(0xFF8AB4FF), size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Local AI Chat',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (widget.openFileName != null)
                  Flexible(
                    child: Text(
                      widget.openFileName!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg.role == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    constraints: const BoxConstraints(maxWidth: 320),
                    decoration: BoxDecoration(
                      color: isUser
                          ? const Color(0xFF2A3A5C)
                          : const Color(0xFF1C2130),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SelectableText(
                      msg.content,
                      style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Ask about this file…',
                      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
                      filled: true,
                      fillColor: const Color(0xFF0F1218),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
