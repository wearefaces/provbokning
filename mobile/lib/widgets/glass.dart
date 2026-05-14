import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme.dart';

/// Animated gradient background that sits behind every screen.
class GlassBackground extends StatelessWidget {
  final Widget child;
  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: GlassPalette.bgGradient,
              ),
            ),
          ),
        ),
        // Soft colored "blobs" diffused behind the glass surfaces.
        Positioned(
          top: -100,
          right: -60,
          child: _Blob(color: GlassPalette.accent.withOpacity(0.45), size: 320),
        ),
        Positioned(
          top: 240,
          left: -80,
          child:
              _Blob(color: const Color(0xFFAF52DE).withOpacity(0.35), size: 260),
        ),
        Positioned(
          bottom: -120,
          right: -40,
          child:
              _Blob(color: const Color(0xFF30D158).withOpacity(0.25), size: 300),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;
  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withOpacity(0)],
          ),
        ),
      ),
    );
  }
}

/// A frosted-glass panel: blurred backdrop, subtle stroke, soft shadow.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final Color? tint;
  final BorderSide? border;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 22,
    this.blur = 26,
    this.tint,
    this.border,
    this.onTap,
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final fill = tint ?? GlassPalette.surfaceTint;
    final body = ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                fill.withOpacity(0.55),
                fill.withOpacity(0.18),
              ],
            ),
            border: Border.fromBorderSide(
              border ??
                  const BorderSide(color: GlassPalette.surfaceStroke, width: 0.8),
            ),
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
    final wrapped = Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: body,
    );
    if (onTap == null) return wrapped;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: r,
        child: wrapped,
      ),
    );
  }
}

/// Pill-shaped translucent button with gradient fill.
class GlassButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool loading;
  final bool expand;

  const GlassButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = true,
    this.loading = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || loading;
    final colors = primary
        ? [GlassPalette.accent, GlassPalette.accentSoft]
        : [GlassPalette.surfaceTint, GlassPalette.surfaceTint];
    final radius = BorderRadius.circular(18);
    final child = AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: disabled && !loading ? 0.5 : 1,
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors
                    .map((c) => c.withOpacity(primary ? 0.95 : 0.45))
                    .toList(),
              ),
              borderRadius: radius,
              border: Border.all(color: Colors.white.withOpacity(0.25)),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                else if (icon != null)
                  Icon(icon, size: 18, color: Colors.white),
                if (loading || icon != null) const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final tappable = GestureDetector(
      onTap: disabled ? null : onPressed,
      child: child,
    );
    return expand ? SizedBox(width: double.infinity, child: tappable) : tappable;
  }
}

class GlassChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  const GlassChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(14);
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                colors: selected
                    ? [
                        GlassPalette.accent.withOpacity(0.85),
                        GlassPalette.accentSoft.withOpacity(0.65),
                      ]
                    : [
                        Colors.white.withOpacity(0.18),
                        Colors.white.withOpacity(0.08),
                      ],
              ),
              border: Border.all(
                color: selected
                    ? Colors.white.withOpacity(0.35)
                    : Colors.white.withOpacity(0.18),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass-styled text input.
class GlassField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType keyboardType;
  final int? maxLength;
  final IconData? icon;

  const GlassField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType = TextInputType.text,
    this.maxLength,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 6, bottom: 6),
          child: Text(label,
              style: const TextStyle(
                  color: GlassPalette.textSecondary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withOpacity(0.18)),
              ),
              child: TextField(
                controller: controller,
                keyboardType: keyboardType,
                maxLength: maxLength,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                cursorColor: GlassPalette.accentSoft,
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(color: GlassPalette.textMuted),
                  prefixIcon: icon == null
                      ? null
                      : Icon(icon, color: GlassPalette.textSecondary, size: 18),
                  border: InputBorder.none,
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 14),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class GlassDivider extends StatelessWidget {
  const GlassDivider({super.key});
  @override
  Widget build(BuildContext context) => Container(
        height: 0.7,
        color: Colors.white.withOpacity(0.12),
        margin: const EdgeInsets.symmetric(vertical: 12),
      );
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 22, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: const TextStyle(
                            color: GlassPalette.textMuted, fontSize: 13)),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
