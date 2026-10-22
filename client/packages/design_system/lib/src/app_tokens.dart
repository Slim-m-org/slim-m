// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';

import 'app_token_colors.dart';

export 'app_token_colors.dart';

/// Semantic design tokens for slim-m, exposed as a [ThemeExtension] so a widget
/// does one lookup (`Theme.of(context).extension<AppTokens>()`).
///
/// Shaped by the 2026-07-26 visual identity review (see
/// `docs/decisions/0004-visual-identity-review.md`). Three things it changed
/// that are worth knowing before editing this file:
///
/// - **One accent token could not do two jobs.** A value legible as text and a
///   value recognisable as a fill are different colours, which is why light and
///   dark did not read as the same brand. The roles are split now, and the
///   contrast gate checks honest pairs instead of forcing one value through
///   both.
/// - **On true black the border is the whole elevation system.** Dark mode can
///   lean on fill difference; `#000000` cannot, so the hairline carries it
///   alone and had to be raised.
/// - **The accent is rare on purpose.** Seven roles, listed in the decision
///   record, and that list is closed. The failure mode is not a wrong hue, it
///   is the next contributor adding an accent border to something that looked
///   plain.
///
/// The accent hue is settled: glacier cyan, decided 2026-07-27 (option B in the
/// decision record). It is not the review's stated reason, which a deuteranopia
/// simulation of the real render measured and found wrong; the reason it holds
/// is that teal loses 74% of its chroma under deuteranopia and stops reading as
/// a colour, while cyan keeps effectively all of it. Every value below is
/// derived from two anchors, `#1B6F91` light and `#58B4D8` dark, by preserving
/// the teal family's own OKLCh offsets from its anchor, so this was a hue move
/// rather than a retune. Do not hardcode any of these values in widgets.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.surfaceSunken,
    required this.surfaceBase,
    required this.surfaceRaised,
    required this.borderSubtle,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.accent,
    required this.accentFill,
    required this.accentOn,
    required this.accentSoft,
    required this.accentRing,
    required this.focusRing,
    required this.status,
    required this.dangerText,
    required this.dangerBorder,
    required this.warnText,
    required this.warnSoft,
    required this.stripe,
    required this.code,
  });

  /// A step below [surfaceBase], for the rails. Six surfaces were not enough to
  /// draw the shell without the panes bleeding into each other.
  ///
  /// The three surfaces are a ramp, and the two steps in it are meant to be
  /// comparable: a lower step much smaller than the upper one reads as two
  /// surfaces rather than three, which is exactly the bleeding this token was
  /// added to stop. `surface_ramp_test.dart` measures both steps in OKLab
  /// lightness and fails if either is under half the other. [trueBlack] is
  /// exempt and sets this equal to [surfaceBase] on purpose; see its doc.
  final Color surfaceSunken;
  final Color surfaceBase;
  final Color surfaceRaised;

  /// The default separator. Elevation is border-first, so this does the work
  /// shadows do elsewhere.
  final Color borderSubtle;

  /// The separator for something that must read as an edge rather than a hint:
  /// a focused input, a menu against the surface it floats over.
  ///
  /// Of those two, only the menu uses it: [AppInput] authors its own focus
  /// treatment in `accentFill` because the source design does, and says so at
  /// the top of its file. Until 2026-07-27 the menu did not use it either, so
  /// this token was declared, valued in three themes, copied and lerped, and
  /// referenced by no widget - which meant a system with two border weights
  /// only ever drew the weaker one.
  ///
  /// [light]'s value was darkened from #C4CAD1 on 2026-08-25: that cleared
  /// only 1.55:1 against [surfaceBase], the surface a floating menu sits over,
  /// against the 3:1 WCAG 1.4.11 asks of a UI component boundary. The new
  /// value is the same blue-grey hue scaled down, reaching 3.11:1 against
  /// [surfaceBase] and 3.31:1 against [surfaceRaised]. [dark] and [trueBlack]
  /// already cleared 3:1 and were left alone.
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;

  /// Text that is present but not actionable. Deliberately not
  /// [textSecondary] at lower opacity: a disabled control and a de-emphasised
  /// one are different claims, and reusing one colour for both means a user
  /// cannot tell which they are looking at.
  final Color textDisabled;

  /// The accent as *text or icon*: contrast-bound, so it is darker in light
  /// mode and does not match [accentFill]'s hue exactly. Use for accented
  /// labels and glyphs on an ordinary surface.
  ///
  /// [light]'s value was darkened from #1E7F77 by the identity review's own
  /// consequence: adding [surfaceSunken] gave the accent a third surface to be
  /// legible on, and the old value cleared base at 4.53:1 but only reached
  /// 4.26:1 on sunken. The rails are sunken and do carry accent (active channel
  /// marker, unread badge), so that combination is real rather than theoretical.
  final Color accent;

  /// The accent as a *fill*: brand-true and the same hue in every theme, always
  /// paired with [accentOn] for whatever sits on top of it. Use for the one
  /// filled button per screen.
  final Color accentFill;

  /// What is legible on top of [accentFill].
  final Color accentOn;

  /// A ~12% tint of the accent, which does most of the actual accent work:
  /// selected rows, active channel background, operator chips.
  final Color accentSoft;

  /// A wider, fainter accent tint for the ring around a pressed or dragged
  /// control. Distinct from [accentSoft] because the two are seen together and
  /// an identical value collapses the ring into the fill.
  final Color accentRing;

  /// The keyboard focus indicator.
  ///
  /// **This is currently the same value as [accentFill] in every theme**, which
  /// the design system intends: its own `--focus-ring` is defined as
  /// `var(--accent-fill)`. It stays a separate token so that a future decision
  /// to give focus its own hue is one edit here rather than a search for every
  /// accent border that happened to mean focus.
  ///
  /// Because the colour is shared, **shape is what separates focus from
  /// selection**, and that separation is not optional: a keyboard user who
  /// cannot tell the two apart has lost their place. The house rule, which the
  /// components follow and test, is that selection is a *fill* plus a marker
  /// while focus is an *outline ring* drawn around the whole control. A widget
  /// that signals focus with a fill is a bug even though it uses this token.
  ///
  /// An earlier version of this comment claimed the two were deliberately
  /// different colours. They never have been, and a test written against that
  /// claim failed honestly and found it.
  final Color focusRing;

  /// Presence colours. Always paired with a distinct shape, never used alone:
  /// the traffic-light convention is invisible to the most common form of
  /// colour blindness, and a status dot is the smallest thing on screen.
  final AppStatusColors status;

  /// Destructive text, and the border of a destructive control.
  final Color dangerText;
  final Color dangerBorder;

  /// A caution that is not a failure: an expiring invite, a stale device.
  final Color warnText;
  final Color warnSoft;

  /// Diagonal hatching for imagery that has not loaded or has not been
  /// supplied. Its own token so a placeholder never gets drawn as a flat grey
  /// block that reads like a real, empty surface.
  final Color stripe;

  /// Syntax colours for fenced code blocks.
  final AppCodeColors code;

  /// Cool-slate light theme.
  static const AppTokens light = AppTokens(
    surfaceSunken: Color(0xFFEFF1F3),
    surfaceBase: Color(0xFFF7F8F9),
    surfaceRaised: Color(0xFFFFFFFF),
    borderSubtle: Color(0xFFDCE0E5),
    // Was #C4CAD1 until 2026-08-25; see this token's own doc for the ratio.
    borderStrong: Color(0xFF858A8F),
    textPrimary: Color(0xFF1B1E22),
    textSecondary: Color(0xFF5B6169),
    textDisabled: Color(0xFF8A929B),
    // The decision record's light anchor, verbatim. Darker than the teal it
    // replaces, so it clears sunken (the rails) by more: 4.97:1 against 4.55:1.
    accent: Color(0xFF1B6F91),
    accentFill: Color(0xFF1B6F91),
    accentOn: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFDAE9F2),
    accentRing: Color(0x381B6F91),
    focusRing: Color(0xFF1B6F91),
    status: AppStatusColors.light,
    dangerText: Color(0xFFA83B32),
    dangerBorder: Color(0xFFC0524A),
    warnText: Color(0xFF7A5A22),
    warnSoft: Color(0x1FC08A2E),
    stripe: Color(0x175B6169),
    code: AppCodeColors.light,
  );

  /// Hand-tuned dark theme (not a mechanical inversion of light).
  static const AppTokens dark = AppTokens(
    // Was #131518, which put the rails only 1.77 OKLab L below base while base
    // sits 3.80 below raised. Even steps, the way light's ramp already is.
    surfaceSunken: Color(0xFF0F1113),
    surfaceBase: Color(0xFF17191C),
    surfaceRaised: Color(0xFF1F2226),
    borderSubtle: Color(0xFF2E333A),
    borderStrong: Color(0xFF6C757E),
    textPrimary: Color(0xFFECEDEF),
    textSecondary: Color(0xFFA7AEB6),
    textDisabled: Color(0xFF6C757E),
    accent: Color(0xFF58B4D8),
    accentFill: Color(0xFF58B4D8),
    accentOn: Color(0xFF070E12),
    accentSoft: Color(0xFF1D2B33),
    accentRing: Color(0x4058B4D8),
    focusRing: Color(0xFF58B4D8),
    status: AppStatusColors.dark,
    dangerText: Color(0xFFD4756B),
    dangerBorder: Color(0xFFC0524A),
    warnText: Color(0xFFC08A2E),
    warnSoft: Color(0x1AC08A2E),
    stripe: Color(0x12A7AEB6),
    code: AppCodeColors.dark,
  );

  /// True black, for OLED panels where a pure black pixel is genuinely off.
  /// Not merely "darker dark": the point is the unlit pixel, so the base is
  /// #000000 and elevation is carried by borders rather than lighter fills.
  ///
  /// The hairline is brighter here than in [dark] on purpose. With sunken, base
  /// and raised all collapsing toward black, the rails stop being surfaces and
  /// become regions defined only by their edges, so a border that reads as a
  /// hint in dark mode disappears entirely at low OLED brightness.
  static const AppTokens trueBlack = AppTokens(
    surfaceSunken: Color(0xFF000000),
    surfaceBase: Color(0xFF000000),
    surfaceRaised: Color(0xFF0B0D0F),
    borderSubtle: Color(0xFF2C3238),
    borderStrong: Color(0xFF6C757E),
    textPrimary: Color(0xFFF2F5F7),
    textSecondary: Color(0xFFA8B2BC),
    textDisabled: Color(0xFF6C757E),
    // Carries more chroma than dark's accent at essentially the same lightness,
    // which is the shift the teal family made here rather than a fresh choice.
    accent: Color(0xFF40B6D9),
    accentFill: Color(0xFF40B6D9),
    accentOn: Color(0xFF030E12),
    accentSoft: Color(0xFF12262D),
    accentRing: Color(0x3D40B6D9),
    focusRing: Color(0xFF40B6D9),
    status: AppStatusColors.dark,
    dangerText: Color(0xFFD4756B),
    dangerBorder: Color(0xFFC0524A),
    warnText: Color(0xFFC08A2E),
    warnSoft: Color(0x1AC08A2E),
    stripe: Color(0x12A8B2BC),
    code: AppCodeColors.trueBlack,
  );

  /// Catppuccin Mocha (MIT, see docs/decisions/0088). Surfaces step crust,
  /// base, surface0 because mantle, base, surface0 fails the ramp gate.
  static const AppTokens mocha = AppTokens(
    surfaceSunken: Color(0xFF11111B),
    surfaceBase: Color(0xFF1E1E2E),
    surfaceRaised: Color(0xFF313244),
    borderSubtle: Color(0xFF45475A),
    borderStrong: Color(0xFF7F849C),
    textPrimary: Color(0xFFCDD6F4),
    textSecondary: Color(0xFFA6ADC8),
    textDisabled: Color(0xFF6C7086),
    accent: Color(0xFFCBA6F7),
    accentFill: Color(0xFFCBA6F7),
    accentOn: Color(0xFF11111B),
    accentSoft: Color(0xFF38324C),
    accentRing: Color(0x40CBA6F7),
    focusRing: Color(0xFFCBA6F7),
    status: AppStatusColors.mocha,
    dangerText: Color(0xFFF38BA8),
    dangerBorder: Color(0xFFEBA0AC),
    warnText: Color(0xFFF9E2AF),
    warnSoft: Color(0x1AF9E2AF),
    stripe: Color(0x12A6ADC8),
    code: AppCodeColors.mocha,
  );

  /// A dimmer grey dark, between [dark] and the daylight of [light]. Same cool
  /// slate neutrals and glacier accent as [dark], lifted a step or two.
  static const AppTokens soft = AppTokens(
    surfaceSunken: Color(0xFF22262B),
    surfaceBase: Color(0xFF2B3036),
    surfaceRaised: Color(0xFF363C44),
    borderSubtle: Color(0xFF454C55),
    borderStrong: Color(0xFF8A939D),
    textPrimary: Color(0xFFECEDEF),
    textSecondary: Color(0xFFB3BAC2),
    textDisabled: Color(0xFF7C858F),
    accent: Color(0xFF6CC0E2),
    accentFill: Color(0xFF6CC0E2),
    accentOn: Color(0xFF070E12),
    accentSoft: Color(0xFF2C4A58),
    accentRing: Color(0x406CC0E2),
    focusRing: Color(0xFF6CC0E2),
    status: AppStatusColors.soft,
    dangerText: Color(0xFFEE9C93),
    dangerBorder: Color(0xFFCF6A60),
    warnText: Color(0xFFDDAA4C),
    warnSoft: Color(0x1ADDAA4C),
    stripe: Color(0x12B3BAC2),
    code: AppCodeColors.soft,
  );

  /// Deep pine surfaces with a seafoam accent of its own, the one theme that
  /// leaves slate behind. See docs/decisions/0089.
  static const AppTokens forest = AppTokens(
    surfaceSunken: Color(0xFF0B1411),
    surfaceBase: Color(0xFF12201B),
    surfaceRaised: Color(0xFF1C2E27),
    borderSubtle: Color(0xFF2B4239),
    borderStrong: Color(0xFF6E8A7E),
    textPrimary: Color(0xFFE6EFE9),
    textSecondary: Color(0xFFA5B8AE),
    textDisabled: Color(0xFF6B8277),
    accent: Color(0xFF5FD4C4),
    accentFill: Color(0xFF5FD4C4),
    accentOn: Color(0xFF05130F),
    accentSoft: Color(0xFF1B4640),
    accentRing: Color(0x405FD4C4),
    focusRing: Color(0xFF5FD4C4),
    status: AppStatusColors.forest,
    dangerText: Color(0xFFE58A7B),
    dangerBorder: Color(0xFFD0675B),
    warnText: Color(0xFFD9A441),
    warnSoft: Color(0x1AD9A441),
    stripe: Color(0x12A5B8AE),
    code: AppCodeColors.forest,
  );

  @override
  AppTokens copyWith({
    Color? surfaceSunken,
    Color? surfaceBase,
    Color? surfaceRaised,
    Color? borderSubtle,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? accent,
    Color? accentFill,
    Color? accentOn,
    Color? accentSoft,
    Color? accentRing,
    Color? focusRing,
    AppStatusColors? status,
    Color? dangerText,
    Color? dangerBorder,
    Color? warnText,
    Color? warnSoft,
    Color? stripe,
    AppCodeColors? code,
  }) {
    return AppTokens(
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      surfaceBase: surfaceBase ?? this.surfaceBase,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      accent: accent ?? this.accent,
      accentFill: accentFill ?? this.accentFill,
      accentOn: accentOn ?? this.accentOn,
      accentSoft: accentSoft ?? this.accentSoft,
      borderStrong: borderStrong ?? this.borderStrong,
      textDisabled: textDisabled ?? this.textDisabled,
      accentRing: accentRing ?? this.accentRing,
      focusRing: focusRing ?? this.focusRing,
      status: status ?? this.status,
      dangerText: dangerText ?? this.dangerText,
      dangerBorder: dangerBorder ?? this.dangerBorder,
      warnText: warnText ?? this.warnText,
      warnSoft: warnSoft ?? this.warnSoft,
      stripe: stripe ?? this.stripe,
      code: code ?? this.code,
    );
  }

  @override
  AppTokens lerp(covariant AppTokens? other, double t) {
    if (other == null) return this;
    return AppTokens(
      surfaceSunken: Color.lerp(surfaceSunken, other.surfaceSunken, t)!,
      surfaceBase: Color.lerp(surfaceBase, other.surfaceBase, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentFill: Color.lerp(accentFill, other.accentFill, t)!,
      accentOn: Color.lerp(accentOn, other.accentOn, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      accentRing: Color.lerp(accentRing, other.accentRing, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      status: t < 0.5 ? status : other.status,
      dangerText: Color.lerp(dangerText, other.dangerText, t)!,
      dangerBorder: Color.lerp(dangerBorder, other.dangerBorder, t)!,
      warnText: Color.lerp(warnText, other.warnText, t)!,
      warnSoft: Color.lerp(warnSoft, other.warnSoft, t)!,
      stripe: Color.lerp(stripe, other.stripe, t)!,
      code: t < 0.5 ? code : other.code,
    );
  }
}

/// Colours for objects drawn on the Voice Canvas.
///
/// Deliberately warmer and more saturated than the chrome. The canvas is the
/// one place allowed more energy, and the energy is meant to come from the
/// content rather than from restyling the app around it.
///
/// [cursors] is a closed set of six categorical hues for remote participants.
/// They must not reuse the status hues or the accent, or a cursor reads as a
/// presence indicator.
abstract final class AppCanvasColors {
  static const Color annotation = Color(0xFFE86A5C);
  static const Color note = Color(0xFFE8B04B);
  static const Color shape = Color(0xFF5B8FD6);
  static const Color penGreen = Color(0xFF6FBF73);
  static const Color penPurple = Color(0xFF8C6FE0);
  static const Color penPink = Color(0xFFE0699A);

  static const List<Color> cursors = [
    Color(0xFFE0699A),
    Color(0xFF8C6FE0),
    Color(0xFF3FA9C9),
    Color(0xFFD98A3F),
    Color(0xFF6FBF73),
    Color(0xFFC96FB8),
  ];
}

/// A webhook or bot embed's colour, reduced server-side to one of six
/// swatches - painted only as a border stripe, never as text.
abstract final class AppEmbedAccents {
  static const Color red = Color(0xFFE0685C);
  static const Color orange = Color(0xFFD98A3F);
  static const Color yellow = Color(0xFFD9B23F);
  static const Color green = Color(0xFF6FBF73);
  static const Color blue = Color(0xFF5B8FD6);
  static const Color purple = Color(0xFF8C6FE0);
}
