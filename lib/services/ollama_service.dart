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

class OllamaService {
  OllamaService({
    this.baseUrl = 'http://127.0.0.1:11434',
    this.chatModel = 'qwen2.5-coder:3b',
    this.embedModel = 'nomic-embed-text',
  });

  final String baseUrl;
  String chatModel;
  final String embedModel;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

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
    final response = await http
        .post(
          _uri('/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'model': model ?? chatModel,
            'stream': false,
            'messages': [
              for (final m in messages) {'role': m.role, 'content': m.content},
            ],
          }),
        )
        .timeout(const Duration(minutes: 2));

    if (response.statusCode != 200) {
      throw Exception('Ollama chat failed: HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final message = data['message'] as Map<String, dynamic>?;
    return message?['content'] as String? ?? '';
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
}
