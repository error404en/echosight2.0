import 'package:flutter/material.dart';

enum AssistantMode {
  assistant,
  surroundings,
  sight,
  navigate,
  reader,
  identify,
  emergency,
}

extension AssistantModeExtension on AssistantMode {
  String get name {
    switch (this) {
      case AssistantMode.assistant:
        return 'Assistant';
      case AssistantMode.surroundings:
        return 'Surroundings';
      case AssistantMode.sight:
        return 'Sight';
      case AssistantMode.navigate:
        return 'Navigate';
      case AssistantMode.reader:
        return 'Reader';
      case AssistantMode.identify:
        return 'Identify';
      case AssistantMode.emergency:
        return 'Emergency';
    }
  }

  IconData get icon {
    switch (this) {
      case AssistantMode.assistant:
        return Icons.smart_toy_outlined;
      case AssistantMode.surroundings:
        return Icons.visibility;
      case AssistantMode.sight:
        return Icons.remove_red_eye_outlined;
      case AssistantMode.navigate:
        return Icons.explore_outlined;
      case AssistantMode.reader:
        return Icons.auto_stories_outlined;
      case AssistantMode.identify:
        return Icons.search_outlined;
      case AssistantMode.emergency:
        return Icons.emergency_outlined;
    }
  }

  Color get color {
    switch (this) {
      case AssistantMode.assistant:
        return Colors.blueAccent;
      case AssistantMode.surroundings:
        return Colors.cyanAccent;
      case AssistantMode.sight:
        return Colors.indigoAccent;
      case AssistantMode.navigate:
        return Colors.greenAccent;
      case AssistantMode.reader:
        return Colors.purpleAccent;
      case AssistantMode.identify:
        return Colors.orangeAccent;
      case AssistantMode.emergency:
        return Colors.redAccent;
    }
  }

  String get description {
    switch (this) {
      case AssistantMode.assistant:
        return 'General vision and Q&A';
      case AssistantMode.surroundings:
        return 'Brief updates on what changed';
      case AssistantMode.sight:
        return 'Rich sight-like view of your surroundings';
      case AssistantMode.navigate:
        return 'Focus on obstacles and safety';
      case AssistantMode.reader:
        return 'Focus on reading text aloud';
      case AssistantMode.identify:
        return 'Detailed object descriptions';
      case AssistantMode.emergency:
        return 'Immediate danger assessment';
    }
  }
}
