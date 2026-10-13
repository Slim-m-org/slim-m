// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The ThemeData built from a token set.
///
/// Split from `app_tokens.dart` when the component themes pushed that file
/// past the 500-line ceiling; the tokens stay a value catalogue and this is
/// the one place they compile into Material.
library;

import 'package:flutter/material.dart';

import 'app_metrics.dart';
import 'app_tokens.dart';
import 'app_typography.dart';
import 'components/surfaces/sheet.dart' show kSheetMaxWidth;

/// Names [AppFonts.sans] on [style] explicitly, for a style handed straight
/// to a Material component theme that resolves it with `??` rather than
/// merging it over its own default.
///
/// No `AppText.*` style carries its own `fontFamily`; a leaf `Text` merges
/// its style with the ambient `DefaultTextStyle`, and `ThemeData` applies
/// [AppFonts.sans] onto every entry of `textTheme` for exactly that reason
/// (see `buildTheme`'s own doc comment). `ListTile` does not go through that
/// merge: it resolves its title as `titleTextStyle ?? tileTheme.titleTextStyle
/// ?? defaults.titleTextStyle`, so a family-less style assigned to
/// [ListTileThemeData.titleTextStyle] wins outright and silently renders in
/// the platform's default face rather than IBM Plex Sans. Checked and found
/// not to apply to `InputDecorationTheme`'s label, hint, helper and error
/// styles: `InputDecorator` resolves each of those through a proper merge
/// with its own family-carrying default, confirmed empirically rather than
/// assumed, so they are deliberately left unwrapped here.
/// `app_theme_font_test.dart` is the regression guard.
TextStyle _familyNamed(TextStyle style) => style.copyWith(
      fontFamily: AppFonts.sans,
      fontFamilyFallback: AppFonts.emoji,
    );

/// The focus ring every `App*` component already draws, applied here so a
/// raw `TextButton`/`FilledButton`/`IconButton` (the handful of call sites
/// that never reached for `AppButton`/`AppIconButton`) gets it too, instead
/// of falling back to Material's own translucent focus overlay.
///
/// `ButtonStyleButton.resolve` (Flutter's shared build path for all three
/// widgets) resolves `style?.side` per-state and only falls through to the
/// next style below it when this one's own resolved value is null, so an
/// unfocused button still resolves to whatever its own default border is
/// (none, for all three): this is additive, never a replacement.
///
/// Value equality is load-bearing rather than tidy. `MaterialApp` wraps its
/// theme in an `AnimatedTheme`, so a `ThemeData` that never compares equal to
/// the last one makes every rebuild animate - and `AnimatedTheme` does not
/// consult reduce-motion, so it animates there too. `resolveWith`'s own
/// closure compares by identity, which is exactly that trap, so this is a
/// named class holding only the colour it varies on.
@immutable
class _FocusRingSide implements WidgetStateProperty<BorderSide?> {
  const _FocusRingSide(this.color);

  final Color color;

  @override
  BorderSide? resolve(Set<WidgetState> states) =>
      states.contains(WidgetState.focused)
          ? BorderSide(color: color, width: 2)
          : null;

  @override
  bool operator ==(Object other) =>
      other is _FocusRingSide && other.color == color;

  @override
  int get hashCode => color.hashCode;
}

WidgetStateProperty<BorderSide?> _focusRingSide(AppTokens tokens) =>
    _FocusRingSide(tokens.focusRing);

/// Builds a theme from the token set, so widgets read colours from tokens and
/// never from raw literals. Shared by the app and the golden tests, which is
/// what keeps goldens representative of what ships.
///
/// The component themes below are what keep a raw Material widget on the
/// system when it slips past the `App*` components: without them a bare
/// `FilledButton` is a Material stadium pill and a bare `TextField` an
/// underline, which is exactly how the production review found every screen
/// drifting toward default Material. Buttons take the control radius (6, not
/// full), inputs take the hairline box `AppInput` draws, and the text theme
/// carries this system's scale, whose heaviest weight is 600 by rule.
///
/// Both accent roles are pinned to their tokens rather than left to
/// `fromSeed`, for one reason: Material derives its own tone from the seed,
/// and a derived tone is a different colour from the hand-picked token even
/// when the seed *is* that token. `error` was pinned an audit round ago after
/// two reds meaning "danger" turned up across the app. `primary` was left out
/// and had the same effect on every raw `FilledButton`, `TextButton` and
/// `OutlinedButton`, so the front door's button and the wordmark beside it
/// were measurably two different accents. Pinning both makes any raw
/// `colorScheme.primary` or `.error` correct by construction rather than by
/// every call site remembering.
///
/// `bottomSheetTheme` is pinned for the same reason, found the same way. A
/// sheet is a raised surface like every other panel here, but left to Material
/// it painted its own generated `surfaceContainerLow` instead of the palette's
/// `surfaceRaised`. `showAppSheet` renders a dialog on a desktop and a bottom
/// sheet on a phone, and only the dialog passed a colour, so the same sheet
/// with the same content was a different colour on the two shapes, and the
/// strip a bottom sheet reserves for the home indicator read as a seam under
/// its last row. `sheet_surface_test.dart` is the regression guard.
ThemeData buildTheme(Brightness brightness, AppTokens tokens) {
  // Overridden, never left to fromSeed; see this function's own doc comment.
  final scheme = ColorScheme.fromSeed(
    seedColor: tokens.accentFill,
    brightness: brightness,
  ).copyWith(
    surface: tokens.surfaceBase,
    primary: tokens.accentFill,
    onPrimary: tokens.accentOn,
    error: tokens.dangerText,
  );

  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadii.control),
  );
  // Named explicitly; see _familyNamed's own doc comment for why.
  final buttonLabel = _familyNamed(
    AppText.ui.copyWith(fontWeight: AppWeights.semi),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.surfaceBase,
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.emoji,
    extensions: [tokens],
    dividerTheme: DividerThemeData(color: tokens.borderSubtle, space: 1),
    // A sheet is a raised surface like every other panel; see this function's doc.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: tokens.borderStrong,
      elevation: 0,
      modalElevation: 0,
    ),
    textTheme: TextTheme(
      headlineSmall: AppText.title.copyWith(color: tokens.textPrimary),
      titleLarge: AppText.heading.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.semi,
      ),
      titleMedium: AppText.body.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.medium,
      ),
      titleSmall: AppText.ui.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.medium,
      ),
      bodyLarge: AppText.body.copyWith(color: tokens.textPrimary),
      bodyMedium: AppText.ui.copyWith(color: tokens.textPrimary),
      bodySmall: AppText.caption.copyWith(color: tokens.textSecondary),
      labelLarge: buttonLabel,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.surfaceBase,
      foregroundColor: tokens.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: AppText.heading.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.semi,
        fontFamily: AppFonts.sans,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: controlShape).copyWith(
        textStyle: WidgetStatePropertyAll(buttonLabel),
        side: _focusRingSide(tokens),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(shape: controlShape).copyWith(
        textStyle: WidgetStatePropertyAll(buttonLabel),
        side: _focusRingSide(tokens),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(shape: controlShape).copyWith(
        textStyle: WidgetStatePropertyAll(buttonLabel),
        side: _focusRingSide(tokens),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: controlShape).copyWith(
        textStyle: WidgetStatePropertyAll(buttonLabel),
        side: _focusRingSide(tokens),
      ),
    ),
    // No raw call site sets its own `side`, so this is purely additive; see
    // `_focusRingSide`'s own doc comment.
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(side: _focusRingSide(tokens)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.surfaceRaised,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s12,
        vertical: AppSpacing.s12,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: tokens.borderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: tokens.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: tokens.focusRing, width: 2),
      ),
      // A failing field is marked on the field itself (error grammar 03):
      // red hairline, red caption, content preserved. The button never
      // turns red - the field failed, not the button.
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: tokens.dangerBorder),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        borderSide: BorderSide(color: tokens.dangerBorder, width: 2),
      ),
      errorStyle: AppText.caption.copyWith(color: tokens.dangerText),
      labelStyle: AppText.body.copyWith(color: tokens.textSecondary),
      floatingLabelStyle: AppText.caption.copyWith(color: tokens.textSecondary),
      hintStyle: AppText.body.copyWith(color: tokens.textSecondary),
      helperStyle: AppText.caption.copyWith(color: tokens.textSecondary),
    ),
    scrollbarTheme: ScrollbarThemeData(
      // fromMap, not resolveWith: a closure never compares equal, so every rebuild would restart AnimatedTheme.
      thickness: WidgetStateProperty<double?>.fromMap({
        WidgetState.hovered | WidgetState.dragged: AppSpacing.s8,
        WidgetState.any: AppSpacing.s4,
      }),
      thumbColor: WidgetStateProperty<Color?>.fromMap({
        WidgetState.hovered | WidgetState.dragged:
            tokens.textSecondary.withValues(alpha: 0.6),
        WidgetState.any: tokens.textSecondary.withValues(alpha: 0.28),
      }),
      trackVisibility: const WidgetStatePropertyAll(false),
      radius: const Radius.circular(AppSpacing.s4),
      crossAxisMargin: 2,
    ),
    // Raw ListTiles took M3's onSurface, putting two blacks in one panel.
    listTileTheme: ListTileThemeData(
      textColor: tokens.textPrimary,
      iconColor: tokens.textSecondary,
      titleTextStyle: _familyNamed(
        AppText.body.copyWith(color: tokens.textPrimary),
      ),
      subtitleTextStyle: _familyNamed(
        AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    ),
    // Rendered and found stock: a plain light-grey bar full-bleed across a
    // wide desktop window, in a dark app whose every other surface is
    // border-first. `AppCard`'s own fill/border/radius, `floating` and
    // `kSheetMaxWidth` so it reads as a panel rather than spanning the window.
    // `SnackBar` builds its content under a bare `DefaultTextStyle`, never a
    // `.merge`, the same trap `_familyNamed`'s own doc comment already names
    // for `ListTileThemeData` - so this needs it too or the family is lost.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tokens.surfaceRaised,
      contentTextStyle: _familyNamed(
        AppText.body.copyWith(color: tokens.textPrimary),
      ),
      actionTextColor: tokens.accentFill,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      width: kSheetMaxWidth,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.card),
        side: BorderSide(color: tokens.borderSubtle),
      ),
    ),
  );
}
