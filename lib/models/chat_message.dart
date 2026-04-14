/// Data model for chat messages displayed in the transcript.
class ChatMessage {
  final String id;
  final String content;
  final MessageRole role;
  final DateTime timestamp;
  final bool hasVisionContext;
  final Map<String, dynamic>? visionContext;

  ChatMessage({
    String? id,
    required this.content,
    required this.role,
    DateTime? timestamp,
    this.hasVisionContext = false,
    this.visionContext,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'content': content,
        'role': role.name,
        'timestamp': timestamp.toIso8601String(),
        'hasVisionContext': hasVisionContext,
      };
}

enum MessageRole {
  user,
  assistant,
  system,
}
