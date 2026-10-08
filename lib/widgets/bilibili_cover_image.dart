import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Network image for Bilibili covers/avatars. A null [url] (missing or not on
/// an allowed host) and load failures both show a placeholder.
class BilibiliCoverImage extends StatelessWidget {
  const BilibiliCoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius = 6,
    this.fit = BoxFit.cover,
    this.icon = Icons.smart_display_outlined,
  });

  final String? url;
  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: AppTokens.bgCard,
      child: Center(child: Icon(icon, color: AppTokens.text3, size: 26)),
    );
    final value = url;
    final Widget child = value == null
        ? placeholder
        : Image.network(
            value,
            fit: fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
            frameBuilder: (context, child, frame, wasSync) {
              if (wasSync || frame != null) return child;
              return placeholder;
            },
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(width: width, height: height, child: child),
    );
  }
}

/// Circular avatar that keeps the original image framing (no crop suffix).
class BilibiliAvatar extends StatelessWidget {
  const BilibiliAvatar({super.key, required this.url, this.size = 40});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return BilibiliCoverImage(
      url: url,
      width: size,
      height: size,
      borderRadius: size / 2,
      icon: Icons.person_outline,
    );
  }
}
