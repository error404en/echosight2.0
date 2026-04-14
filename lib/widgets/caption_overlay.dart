import 'package:flutter/material.dart';
import 'dart:ui';
import '../core/theme.dart';

/// Real-time caption overlay with glassmorphism effect.
class CaptionOverlay extends StatelessWidget {
  final String caption;
  final String streamingResponse;
  final bool isVisible;

  const CaptionOverlay({
    super.key,
    required this.caption,
    this.streamingResponse = '',
    this.isVisible = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!isVisible || (caption.isEmpty && streamingResponse.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Positioned(
      bottom: 180,
      left: 16,
      right: 16,
      child: Column(
        children: [
          // User speech caption
          if (caption.isNotEmpty)
            _GlassCard(
              child: Row(
                children: [
                  Icon(Icons.mic, color: EchoSightTheme.listening, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      caption,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (caption.isNotEmpty && streamingResponse.isNotEmpty)
            const SizedBox(height: 8),

          // AI response
          if (streamingResponse.isNotEmpty)
            _GlassCard(
              accentColor: EchoSightTheme.speaking,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.smart_toy, color: EchoSightTheme.speaking, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      streamingResponse,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        height: 1.4,
                      ),
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final Color accentColor;

  const _GlassCard({
    required this.child,
    this.accentColor = EchoSightTheme.listening,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accentColor.withOpacity(0.2),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
