import 'package:flutter/material.dart';

import '../theme/cursor_theme.dart';

void showTopToast(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) {
      CursorColors.bindFrom(context);
      return IgnorePointer(
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 52, left: 70, right: 70),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: CursorColors.hover,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CursorColors.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: CursorColors.fgBright,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 2), () {
    if (entry.mounted) entry.remove();
  });
}
