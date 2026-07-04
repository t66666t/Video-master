import 'package:flutter/material.dart';

class ResponsiveIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? color;

  const ResponsiveIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    
    // Calculate relative sizes based on screen width
    final double buttonSize = (screenWidth * 0.032).clamp(32.0, 40.0);
    final double iconSize = (buttonSize * 0.58).clamp(20.0, 24.0);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(buttonSize / 2),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Container(
            width: buttonSize,
            height: buttonSize,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: iconSize,
              color: color ?? Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class ResponsiveActionButtons extends StatelessWidget {
  final List<Widget> buttons;

  const ResponsiveActionButtons({
    super.key,
    required this.buttons,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    // Relative spacing
    final double spacing = (screenWidth * 0.005).clamp(2.0, 8.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i < buttons.length - 1) SizedBox(width: spacing),
        ],
        SizedBox(width: spacing), // Padding at the end of AppBar
      ],
    );
  }
}
