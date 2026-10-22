// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Literal copies of the design tokens a canvas visual render needs.
///
/// This package deliberately carries no dependency on `slimm_design_system`
/// (see `canvas_painters.dart`'s own library doc), so a real design review of
/// the painted result has nowhere to read the real values from except a
/// literal copy, the same shape `canvas_painters_test.dart`'s own `_ink`
/// constant already uses. Every value below is copied verbatim from
/// `client/packages/design_system/lib/src/app_tokens.dart` as of 2026-08-06;
/// if that file changes, these fall out of date silently; this is a
/// throwaway visual-review harness, not a contract test.
library;

import 'package:flutter/painting.dart';

/// One theme's worth of surface, border and text colours a canvas render
/// touches.
class VisualTheme {
  const VisualTheme({
    required this.name,
    required this.surfaceBase,
    required this.surfaceRaised,
    required this.borderSubtle,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.accentFill,
    required this.stripe,
  });

  final String name;
  final Color surfaceBase;
  final Color surfaceRaised;
  final Color borderSubtle;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color accentFill;
  final Color stripe;

  static const light = VisualTheme(
    name: 'light',
    surfaceBase: Color(0xFFF7F8F9),
    surfaceRaised: Color(0xFFFFFFFF),
    borderSubtle: Color(0xFFDCE0E5),
    textPrimary: Color(0xFF1B1E22),
    textSecondary: Color(0xFF5B6169),
    textDisabled: Color(0xFF8A929B),
    accentFill: Color(0xFF1B6F91),
    stripe: Color(0x175B6169),
  );

  static const dark = VisualTheme(
    name: 'dark',
    surfaceBase: Color(0xFF17191C),
    surfaceRaised: Color(0xFF1F2226),
    borderSubtle: Color(0xFF2E333A),
    textPrimary: Color(0xFFECEDEF),
    textSecondary: Color(0xFFA7AEB6),
    textDisabled: Color(0xFF6C757E),
    accentFill: Color(0xFF58B4D8),
    stripe: Color(0x12A7AEB6),
  );

  static const trueBlack = VisualTheme(
    name: 'true_black',
    surfaceBase: Color(0xFF000000),
    surfaceRaised: Color(0xFF0B0D0F),
    borderSubtle: Color(0xFF2C3238),
    textPrimary: Color(0xFFF2F5F7),
    textSecondary: Color(0xFFA8B2BC),
    textDisabled: Color(0xFF6C757E),
    accentFill: Color(0xFF40B6D9),
    stripe: Color(0x12A8B2BC),
  );

  static const mocha = VisualTheme(
    name: 'mocha',
    surfaceBase: Color(0xFF1E1E2E),
    surfaceRaised: Color(0xFF313244),
    borderSubtle: Color(0xFF45475A),
    textPrimary: Color(0xFFCDD6F4),
    textSecondary: Color(0xFFA6ADC8),
    textDisabled: Color(0xFF6C7086),
    accentFill: Color(0xFFCBA6F7),
    stripe: Color(0x12A6ADC8),
  );

  static const soft = VisualTheme(
    name: 'soft',
    surfaceBase: Color(0xFF2B3036),
    surfaceRaised: Color(0xFF363C44),
    borderSubtle: Color(0xFF454C55),
    textPrimary: Color(0xFFECEDEF),
    textSecondary: Color(0xFFB3BAC2),
    textDisabled: Color(0xFF7C858F),
    accentFill: Color(0xFF6CC0E2),
    stripe: Color(0x12B3BAC2),
  );

  static const forest = VisualTheme(
    name: 'forest',
    surfaceBase: Color(0xFF12201B),
    surfaceRaised: Color(0xFF1C2E27),
    borderSubtle: Color(0xFF2B4239),
    textPrimary: Color(0xFFE6EFE9),
    textSecondary: Color(0xFFA5B8AE),
    textDisabled: Color(0xFF6B8277),
    accentFill: Color(0xFF5FD4C4),
    stripe: Color(0x12A5B8AE),
  );

  static const all = [light, dark, trueBlack, mocha, soft, forest];
}

/// `AppCanvasColors`, copied verbatim - the same three per-kind ink roles and
/// the six-hue cursor palette, identical in every theme by design.
abstract final class VisualCanvasColors {
  static const Color annotation = Color(0xFFE86A5C);
  static const Color note = Color(0xFFE8B04B);
  static const Color shape = Color(0xFF5B8FD6);

  static const List<Color> cursors = [
    Color(0xFFE0699A),
    Color(0xFF8C6FE0),
    Color(0xFF3FA9C9),
    Color(0xFFD98A3F),
    Color(0xFF6FBF73),
    Color(0xFFC96FB8),
  ];
}

/// `AppShadows.float`, copied verbatim - the one shadow token the canvas is
/// allowed to reach for.
const List<BoxShadow> visualFloatShadow = [
  BoxShadow(color: Color(0x85000000), blurRadius: 64, offset: Offset(0, 24)),
];
