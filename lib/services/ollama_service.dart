import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class OllamaStatus {
  const OllamaStatus({
    required this.online,
    required this.models,
    this.error,
  });

  final bool online;
  final List<String> models;
  final String? error;
}

class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  final String role;
  final String content;
}

class ChatCancelledException implements Exception {
  const ChatCancelledException();

  @override
  String toString() => 'Chat cancelled';
}

class OllamaService {
  OllamaService({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.chatModel = 'qwen2.5-coder:3b',
    this.embedModel = 'nomic-embed-text',
  });

  /// Small / mid models that work well for local coding on laptops.
  static const recommendedChatModels = <String>[
    'qwen2.5-coder:1.5b',
    'qwen2.5-coder:3b',
    'qwen2.5:3b',
    'llama3.2:3b',
    'gemma2:2b',
    'phi3:mini',
    'deepseek-coder:1.3b',
  ];

  final String baseUrl;
  String chatModel;
  final String embedModel;

  http.Client? _activeChatClient;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  /// Models ready to use, then recommended ones not yet installed.
  static List<String> catalog(List<String> installed) {
    final seen = <String>{};
    final out = <String>[];
    for (final m in [...installed, ...recommendedChatModels]) {
      if (seen.add(m)) out.add(m);
    }
    return out;
  }

  void cancelChat() {
    final client = _activeChatClient;
    _activeChatClient = null;
    client?.close();
  }

  Future<OllamaStatus> checkStatus() async {
    try {
      final response = await http
          .get(_uri('/api/tags'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        return OllamaStatus(
          online: false,
          models: const [],
          error: 'HTTP ${response.statusCode}',
        );
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final models = (data['models'] as List<dynamic>? ?? [])
          .map((m) => (m as Map<String, dynamic>)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      return OllamaStatus(online: true, models: models);
    } catch (e) {
      return OllamaStatus(online: false, models: const [], error: '$e');
    }
  }

  Future<String> chat({
    required List<ChatMessage> messages,
    String? model,
  }) async {
    cancelChat();
    final client = http.Client();
    _activeChatClient = client;
    try {
      final response = await client
          .post(
            _uri('/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model ?? chatModel,
              'stream': false,
              'messages': [
                for (final m in messages)
                  {'role': m.role, 'content': m.content},
              ],
            }),
          )
          .timeout(const Duration(minutes: 2));

      if (!identical(_activeChatClient, client)) {
        throw const ChatCancelledException();
      }

      if (response.statusCode != 200) {
        throw Exception(_formatHttpError('chat', response));
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final message = data['message'] as Map<String, dynamic>?;
      return message?['content'] as String? ?? '';
    } catch (e) {
      if (e is ChatCancelledException ||
          !identical(_activeChatClient, client)) {
        throw const ChatCancelledException();
      }
      rethrow;
    } finally {
      if (identical(_activeChatClient, client)) {
        _activeChatClient = null;
      }
      client.close();
    }
  }

  String _formatHttpError(String action, http.Response response) {
    String detail = 'HTTP ${response.statusCode}';
    try {
      final data = jsonDecode(response.body);
      if (data is Map && data['error'] != null) {
        detail = '${data['error']}';
      } else if (response.body.trim().isNotEmpty) {
        detail = response.body.trim();
      }
    } catch (_) {
      if (response.body.trim().isNotEmpty) {
        detail = response.body.trim();
      }
    }
    if (response.statusCode == 404 &&
        detail.toLowerCase().contains('not found')) {
      return 'Model "$chatModel" not found. Pull it with: ollama pull $chatModel';
    }
    return 'Ollama $action failed: $detail';
  }

  /// Download a model via Ollama (`ollama pull`). [onProgress] gets a
  /// human status and optional 0–1 fraction when known.
  Future<void> pullModel(
    String name, {
    void Function(String status, double? progress)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', _uri('/api/pull'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'name': name, 'stream': true});
      final streamed = await client.send(request).timeout(
            const Duration(hours: 2),
          );
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        throw Exception(
          'Pull failed (HTTP ${streamed.statusCode}): '
          '${body.trim().isEmpty ? 'unknown error' : body.trim()}',
        );
      }

      final buffer = StringBuffer();
      await for (final chunk in streamed.stream.transform(utf8.decoder)) {
        buffer.write(chunk);
        var text = buffer.toString();
        final lines = text.split('\n');
        buffer
          ..clear()
          ..write(lines.isEmpty ? '' : lines.last);
        for (var i = 0; i < lines.length - 1; i++) {
          final line = lines[i].trim();
          if (line.isEmpty) continue;
          Map<String, dynamic> data;
          try {
            data = jsonDecode(line) as Map<String, dynamic>;
          } catch (_) {
            continue;
          }
          if (data['error'] != null) {
            throw Exception('${data['error']}');
          }
          final status = '${data['status'] ?? 'downloading'}';
          double? progress;
          final completed = data['completed'];
          final total = data['total'];
          if (completed is num && total is num && total > 0) {
            progress = (completed / total).clamp(0.0, 1.0);
          }
          onProgress?.call(status, progress);
        }
      }
    } finally {
      client.close();
    }
  }

  Future<List<double>> embed(String text) async {
    final response = await http
        .post(
          _uri('/api/embeddings'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': embedModel, 'prompt': text}),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Ollama embed failed: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final embedding = data['embedding'] as List<dynamic>? ?? [];
    return embedding.map((e) => (e as num).toDouble()).toList();
  }

  /// Embed several texts in one request (`/api/embed`). Falls back to one
  /// `/api/embeddings` call per text on older Ollama versions.
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const [];
    final response = await http
        .post(
          _uri('/api/embed'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model': embedModel, 'input': texts}),
        )
        .timeout(const Duration(minutes: 2));

    if (response.statusCode == 404 &&
        !response.body.toLowerCase().contains('model')) {
      return [for (final t in texts) await embed(t)];
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 404) {
        throw Exception(
          'Embedding model "$embedModel" not found. Pull it with: ollama pull $embedModel',
        );
      }
      throw Exception('Ollama embed failed: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final embeddings = data['embeddings'] as List<dynamic>? ?? [];
    return [
      for (final e in embeddings)
        (e as List<dynamic>).map((v) => (v as num).toDouble()).toList(),
    ];
  }
}
