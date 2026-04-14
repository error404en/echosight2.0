import 'dart:math';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../services/fusion_engine.dart';

/// Animated microphone button with state-aware visual feedback.
class MicButton extends StatefulWidget {
  final AssistantState state;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double size;

  const MicButton({
    super.key,
    required this.state,
    required this.onTap,
    this.onLongPress,
    this.size = 80,
  });

  @override
  State<MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<MicButton> with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotationController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _rotationController = AnimationController(
      duration: const Duration(milliseconds: 3000),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  void _updateAnimation() {
    switch (widget.state) {
      case AssistantState.listening:
        _pulseController.repeat(reverse: true);
        _rotationController.stop();
        break;
      case AssistantState.processing:
      case AssistantState.thinking:
        _pulseController.stop();
        _rotationController.repeat();
        break;
      case AssistantState.speaking:
        _pulseController.repeat(reverse: true);
        _rotationController.stop();
        break;
      case AssistantState.idle:
        _pulseController.stop();
        _rotationController.stop();
        _pulseController.reset();
        _rotationController.reset();
        break;
    }
  }

  Color get _buttonColor {
    switch (widget.state) {
      case AssistantState.idle:
        return EchoSightTheme.primary;
      case AssistantState.listening:
        return EchoSightTheme.listening;
      case AssistantState.processing:
      case AssistantState.thinking:
        return EchoSightTheme.thinking;
      case AssistantState.speaking:
        return EchoSightTheme.speaking;
    }
  }

  Color get _glowColor {
    switch (widget.state) {
      case AssistantState.idle:
        return EchoSightTheme.primary.withOpacity(0.3);
      case AssistantState.listening:
        return EchoSightTheme.listening.withOpacity(0.4);
      case AssistantState.processing:
      case AssistantState.thinking:
        return EchoSightTheme.thinking.withOpacity(0.3);
      case AssistantState.speaking:
        return EchoSightTheme.speaking.withOpacity(0.3);
    }
  }

  IconData get _icon {
    switch (widget.state) {
      case AssistantState.idle:
        return Icons.mic;
      case AssistantState.listening:
        return Icons.hearing;
      case AssistantState.processing:
      case AssistantState.thinking:
        return Icons.psychology;
      case AssistantState.speaking:
        return Icons.volume_up;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseController, _rotationController]),
        builder: (context, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              // Outer glow ring
              if (widget.state != AssistantState.idle)
                Container(
                  width: widget.size * 1.6 * _pulseAnimation.value,
                  height: widget.size * 1.6 * _pulseAnimation.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _glowColor,
                      width: 2,
                    ),
                  ),
                ),

              // Middle glow ring
              if (widget.state != AssistantState.idle)
                Container(
                  width: widget.size * 1.3 * _pulseAnimation.value,
                  height: widget.size * 1.3 * _pulseAnimation.value,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _glowColor.withOpacity(0.1),
                    border: Border.all(
                      color: _glowColor.withOpacity(0.5),
                      width: 1.5,
                    ),
                  ),
                ),

              // Processing rotation ring
              if (widget.state == AssistantState.processing ||
                  widget.state == AssistantState.thinking)
                Transform.rotate(
                  angle: _rotationController.value * 2 * pi,
                  child: Container(
                    width: widget.size * 1.2,
                    height: widget.size * 1.2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.transparent,
                        width: 3,
                      ),
                      gradient: SweepGradient(
                        colors: [
                          _buttonColor.withOpacity(0),
                          _buttonColor,
                          _buttonColor.withOpacity(0),
                        ],
                      ),
                    ),
                  ),
                ),

              // Main button
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _buttonColor,
                  boxShadow: [
                    BoxShadow(
                      color: _buttonColor.withOpacity(0.5),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  _icon,
                  color: Colors.white,
                  size: widget.size * 0.4,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotationController.dispose();
    super.dispose();
  }
}
