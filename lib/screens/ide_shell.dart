import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../services/ollama_service.dart';
import '../widgets/chat_sidebar.dart';
import '../widgets/transparency_panel.dart';

class IdeShell extends StatefulWidget {
  const IdeShell({super.key});

  @override
  State<IdeShell> createState() => _IdeShellState();
}

class _IdeShellState extends State<IdeShell> {
  final _ollama = OllamaService();
  final _editor = TextEditingController(
    text: '''// Welcome to TryHard IDE (LocalForge)
// Local AI via Ollama — works with Wi‑Fi off.

function greet(name) {
  return "Hello, " + name;
}

console.log(greet("offline world"));
''',
  );
  final _pathController = TextEditingController();

  OllamaStatus? _status;
  String? _openPath;
  String _selection = '';
  bool _chatOpen = true;

  @override
  void initState() {
    super.initState();
    _editor.addListener(_onEditorChanged);
    _refreshOllama();
  }

  void _onEditorChanged() {
    final sel = _editor.selection;
    final next = (!sel.isValid || sel.isCollapsed)
        ? ''
        : sel.textInside(_editor.text);
    if (next != _selection) {
      setState(() => _selection = next);
    }
  }

  @override
  void dispose() {
    _editor.removeListener(_onEditorChanged);
    _editor.dispose();
    _pathController.dispose();
    super.dispose();
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

  Future<void> _openFile() async {
    final raw = _pathController.text.trim();
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
      final content = await file.readAsString();
      setState(() {
        _openPath = raw;
        _editor.text = content;
        _selection = '';
      });
    } catch (e) {
      _snack('Open failed: $e');
    }
  }

  Future<void> _save() async {
    if (_openPath == null || kIsWeb) {
      _snack('Open a file path first to save.');
      return;
    }
    try {
      await File(_openPath!).writeAsString(_editor.text);
      _snack('Saved ${_fileName()}');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  String? _fileName() => _openPath == null ? null : p.basename(_openPath!);

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final editorPane = Column(
      children: [
        _toolbar(),
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF0B0D12),
            child: TextField(
              controller: _editor,
              maxLines: null,
              expands: true,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 13,
                color: Color(0xFFE8ECF5),
                height: 1.45,
              ),
              cursorColor: const Color(0xFF8AB4FF),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(16),
              ),
            ),
          ),
        ),
        TransparencyPanel(
          status: _status,
          model: _ollama.chatModel,
          onModelChanged: (m) => setState(() => _ollama.chatModel = m),
          onRefresh: _refreshOllama,
        ),
      ],
    );

    final chat = ChatSidebar(
      ollama: _ollama,
      openFileName: _fileName(),
      selection: _selection,
      fileContent: _editor.text,
    );

    return Scaffold(
      backgroundColor: const Color(0xFF0B0D12),
      body: wide
          ? Row(
              children: [
                Expanded(flex: 3, child: editorPane),
                if (_chatOpen)
                  SizedBox(
                    width: 360,
                    child: chat,
                  ),
              ],
            )
          : Column(
              children: [
                Expanded(child: editorPane),
                if (_chatOpen)
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.42,
                    child: chat,
                  ),
              ],
            ),
    );
  }

  Widget _toolbar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF12141A),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          const Text(
            'TryHard IDE',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'LocalForge',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _pathController,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: InputDecoration(
                hintText: 'Absolute file path to open…',
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF0B0D12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              onSubmitted: (_) => _openFile(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Open',
            onPressed: _openFile,
            icon: const Icon(Icons.folder_open, color: Colors.white70, size: 20),
          ),
          IconButton(
            tooltip: 'Save',
            onPressed: _save,
            icon: const Icon(Icons.save_outlined, color: Colors.white70, size: 20),
          ),
          IconButton(
            tooltip: _chatOpen ? 'Hide chat' : 'Show chat',
            onPressed: () => setState(() => _chatOpen = !_chatOpen),
            icon: Icon(
              _chatOpen ? Icons.chat_bubble : Icons.chat_bubble_outline,
              color: Colors.white70,
              size: 20,
            ),
          ),
          IconButton(
            tooltip: 'Copy selection',
            onPressed: () async {
              final text = _selection.isNotEmpty ? _selection : _editor.text;
              await Clipboard.setData(ClipboardData(text: text));
              _snack('Copied');
            },
            icon: const Icon(Icons.copy, color: Colors.white70, size: 20),
          ),
        ],
      ),
    );
  }
}
