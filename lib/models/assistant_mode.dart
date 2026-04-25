import 'package:flutter/material.dart';

enum AssistantMode {
  auto,
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
      case AssistantMode.auto:
        return 'Auto';
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
      case AssistantMode.auto:
        return Icons.auto_awesome;
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
      case AssistantMode.auto:
        return Colors.tealAccent;
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
      case AssistantMode.auto:
        return 'Automatically prioritizes safety, reading, and scene detailing';
      case AssistantMode.assistant:
        return 'Ask me anything about what\'s in front of you';
      case AssistantMode.surroundings:
        return 'I continuously scan and tell you what changes around you';
      case AssistantMode.sight:
        return 'I become your eyes — rich, detailed descriptions of everything';
      case AssistantMode.navigate:
        return 'Walking directions with obstacle warnings';
      case AssistantMode.reader:
        return 'I read signs, labels, documents, and screens out loud';
      case AssistantMode.identify:
        return 'Point your camera — I\'ll identify and describe in detail';
      case AssistantMode.emergency:
        return 'Continuous danger scanning, SOS alert, location sharing';
    }
  }
}
