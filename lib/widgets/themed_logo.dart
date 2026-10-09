import 'package:flutter/material.dart';

import '../theme/cursor_theme.dart';

/// Try Hard IDE logo: white line art in dark mode, black in light mode.
///
/// The source JPGs have solid backgrounds, so a color matrix turns
/// brightness into alpha — the background drops out and only the line art
/// is drawn over whatever surface the logo sits on.
class ThemedLogo extends StatelessWidget {
  const ThemedLogo({super.key, required this.size, this.opacity = 1});

  static const darkAsset = 'assets/branding/logo_dark.jpg';
  static const lightAsset = 'assets/branding/logo_light.jpg';

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final dark = CursorColors.isDark;
    final a = opacity.clamp(0.0, 1.0);
    // Line color, with alpha = line brightness (Rec. 709 luminance). The
    // alpha offset is only ever negative — it trims JPEG noise near the
    // background and keeps pixels outside the image transparent.
    final c = dark ? 255.0 : 0.0;
    const cutoff = 24.0;
    const gain = 255 / (255 - cutoff);
    final k = gain * a;
    final matrix = <double>[
      0, 0, 0, 0, c,
      0, 0, 0, 0, c,
      0, 0, 0, 0, c,
      0.2126 * k, 0.7152 * k, 0.0722 * k, 0, -cutoff * k,
    ];

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(matrix),
      child: Image.asset(
        dark ? darkAsset : lightAsset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // Invert the light logo (black on white → white on black) so its
        // lines, not its background, become the opaque part.
        color: dark ? null : Colors.white,
        colorBlendMode: dark ? null : BlendMode.difference,
        errorBuilder: (context, error, stackTrace) => Icon(
          Icons.auto_awesome,
          size: size * 0.6,
          color: CursorColors.fgMuted,
        ),
      ),
    );
  }
}
