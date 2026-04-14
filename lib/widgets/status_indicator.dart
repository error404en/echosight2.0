import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../services/fusion_engine.dart';

/// Status indicator showing current assistant state with animated transitions.
class StatusIndicator extends StatelessWidget {
  final AssistantState state;
  final bool isConnected;

  const StatusIndicator({
    super.key,
    required this.state,
    this.isConnected = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: _backgroundColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _backgroundColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animated dot
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _dotColor,
              boxShadow: [
                BoxShadow(
                  color: _dotColor.withOpacity(0.5),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Status text
          Text(
            state.label,
            style: TextStyle(
              color: _textColor,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          // Connection indicator
          if (!isConnected) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.cloud_off_rounded,
              size: 16,
              color: EchoSightTheme.warning,
            ),
          ],
        ],
      ),
    );
  }

  Color get _backgroundColor {
    switch (state) {
      case AssistantState.idle:
        return EchoSightTheme.textSecondary;
      case AssistantState.listening:
        return EchoSightTheme.listening;
      case AssistantState.processing:
      case AssistantState.thinking:
        return EchoSightTheme.thinking;
      case AssistantState.speaking:
        return EchoSightTheme.speaking;
    }
  }

  Color get _dotColor => _backgroundColor;

  Color get _textColor {
    if (state == AssistantState.idle) return EchoSightTheme.textSecondary;
    return Colors.white;
  }
}
