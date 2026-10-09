import 'dart:convert';

import 'app_storage.dart';
import 'repo_index.dart';

class StoredChatMessage {
  const StoredChatMessage({
    required this.role,
    required this.content,
    this.citations = const [],
    this.isNote = false,
  });

  final String role;
  final String content;
  final List<CitationRef> citations;

  /// UI-only notes (e.g. "Applied edit to …") — shown, not sent to the model.
  final bool isNote;

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (citations.isNotEmpty)
          'citations': [for (final c in citations) c.toJson()],
        if (isNote) 'note': true,
      };

  static StoredChatMessage fromJson(Map<String, dynamic> j) => StoredChatMessage(
        role: j['role'] as String,
        content: j['content'] as String,
        citations: [
          for (final c in j['citations'] as List<dynamic>? ?? const [])
            CitationRef.fromJson(c as Map<String, dynamic>),
        ],
        isNote: j['note'] == true,
      );
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  factory ChatSession.empty() {
    final now = DateTime.now();
    return ChatSession(
      id: now.microsecondsSinceEpoch.toRadixString(36),
      title: 'New chat',
      createdAt: now,
      updatedAt: now,
      messages: [],
    );
  }

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<StoredChatMessage> messages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': [for (final m in messages) m.toJson()],
      };

  static ChatSession fromJson(Map<String, dynamic> j) => ChatSession(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Chat',
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        messages: [
          for (final m in j['messages'] as List<dynamic>? ?? const [])
            StoredChatMessage.fromJson(m as Map<String, dynamic>),
        ],
      );
}

/// Chat sessions saved per workspace, newest first.
class ChatHistoryStore {
  static const _bucket = 'chat_history';
  static const _noWorkspace = '__no_workspace__';
  static const _maxSessions = 50;

  static Future<List<ChatSession>> load(String? rootPath) async {
    try {
      final file = await AppStorage.workspaceFile(_bucket, rootPath ?? _noWorkspace);
      if (!await file.exists()) return [];
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final sessions = [
        for (final s in data['sessions'] as List<dynamic>? ?? const [])
          ChatSession.fromJson(s as Map<String, dynamic>),
      ];
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return sessions;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String? rootPath, List<ChatSession> sessions) async {
    try {
      final file = await AppStorage.workspaceFile(_bucket, rootPath ?? _noWorkspace);
      final kept = sessions.where((s) => s.messages.isNotEmpty).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await AppStorage.writeAtomic(
        file,
        jsonEncode({
          'version': 1,
          'sessions': [for (final s in kept.take(_maxSessions)) s.toJson()],
        }),
      );
    } catch (_) {
      // Best-effort; chat keeps working without persistence.
    }
  }
}
