import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import '../utils/bilibili_image_url.dart';

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

/// Large cover (detail header). Shows the small list thumbnail [url] first,
/// which is usually already cached, then swaps to a sharper size picked from
/// the laid-out width × devicePixelRatio once it has loaded. If the sharp
/// image fails, the thumbnail stays.
class BilibiliSharpCoverImage extends StatelessWidget {
  const BilibiliSharpCoverImage({
    super.key,
    required this.url,
    this.borderRadius = 10,
  });

  /// Thumbnail URL; the sharp URL is derived from the same image path.
  final String? url;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final small = BilibiliCoverImage(url: url, borderRadius: 0);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sharp = bilibiliCoverSharpUrl(url, constraints.maxWidth * dpr);
          if (sharp == null || sharp == url) return small;
          return Image.network(
            sharp,
            key: ValueKey(sharp),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => small,
            frameBuilder: (context, child, frame, wasSync) {
              if (wasSync || frame != null) return child;
              return small;
            },
          );
        },
      ),
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
