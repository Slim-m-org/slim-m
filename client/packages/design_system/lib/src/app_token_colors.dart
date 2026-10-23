// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';

/// Presence colours, one per state.
///
/// The traffic-light convention is used because it is the one users already
/// have, but it is never load-bearing on its own: every presence indicator
/// pairs a hue with a distinct shape (filled disc, hollow ring, dash, crescent)
/// so the state survives greyscale. That matters more than usual here, because
/// a bug report arrives as a screenshot and a status dot is the smallest thing
/// in it.
@immutable
class AppStatusColors {
  const AppStatusColors({
    required this.online,
    required this.away,
    required this.dnd,
    required this.offline,
  });

  final Color online;
  final Color away;
  final Color dnd;
  final Color offline;

  static const AppStatusColors light = AppStatusColors(
    online: Color(0xFF2E7D45),
    away: Color(0xFF8A6218),
    dnd: Color(0xFFA83B32),
    offline: Color(0xFF6C757E),
  );

  static const AppStatusColors dark = AppStatusColors(
    online: Color(0xFF3FA45B),
    away: Color(0xFFC08A2E),
    dnd: Color(0xFFC0524A),
    offline: Color(0xFF6C757E),
  );

  static const AppStatusColors soft = AppStatusColors(
    online: Color(0xFF3FA45B),
    away: Color(0xFFC08A2E),
    dnd: Color(0xFFC0524A),
    offline: Color(0xFF8A939D),
  );

  static const AppStatusColors forest = AppStatusColors(
    online: Color(0xFF3FA45B),
    away: Color(0xFFC08A2E),
    dnd: Color(0xFFC0524A),
    offline: Color(0xFF6E8A7E),
  );

  static const AppStatusColors mocha = AppStatusColors(
    online: Color(0xFFA6E3A1),
    away: Color(0xFFF9E2AF),
    dnd: Color(0xFFF38BA8),
    offline: Color(0xFF6C7086),
  );

  List<Color> get all => [online, away, dnd, offline];
}

/// Syntax colours for fenced code blocks, five roles per theme.
///
/// Per theme because the same string colour cannot clear 4.5:1 on both white
/// and black, and a code block is exactly the surface that quietly ends up the
/// one inaccessible thing in an otherwise AA product.
@immutable
class AppCodeColors {
  const AppCodeColors({
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.punctuation,
  });

  final Color keyword;
  final Color string;
  final Color number;
  final Color comment;
  final Color punctuation;

  /// Comment and punctuation are darker here than the design system's CSS,
  /// which leaves both at slate-400. That is an oversight in the source rather
  /// than a choice: the light block overrides keyword, string and number and
  /// simply does not override these two, so they inherit a value that lands at
  /// about 2.2:1 on white. The rule stated one line above this class is the one
  /// followed.
  static const AppCodeColors light = AppCodeColors(
    keyword: Color(0xFF166B64),
    string: Color(0xFF7A5A22),
    number: Color(0xFF7A5A22),
    comment: Color(0xFF5B6169),
    punctuation: Color(0xFF5B6169),
  );

  static const AppCodeColors dark = AppCodeColors(
    keyword: Color(0xFF8FC7C1),
    string: Color(0xFFC6A882),
    number: Color(0xFFC6A882),
    comment: Color(0xFFA7AEB6),
    punctuation: Color(0xFFA7AEB6),
  );

  static const AppCodeColors trueBlack = AppCodeColors(
    keyword: Color(0xFF79C8BE),
    string: Color(0xFFC9AA84),
    number: Color(0xFFC9AA84),
    comment: Color(0xFFA8B2BC),
    punctuation: Color(0xFFA8B2BC),
  );

  static const AppCodeColors soft = AppCodeColors(
    keyword: Color(0xFF8FC7C1),
    string: Color(0xFFD2B48C),
    number: Color(0xFFD2B48C),
    comment: Color(0xFFB3BAC2),
    punctuation: Color(0xFFB3BAC2),
  );

  static const AppCodeColors forest = AppCodeColors(
    keyword: Color(0xFF5FD4C4),
    string: Color(0xFFE3B778),
    number: Color(0xFFE3B778),
    comment: Color(0xFFA5B8AE),
    punctuation: Color(0xFFA5B8AE),
  );

  /// Comment and punctuation use subtext0: overlay1 and overlay2 fail 4.5:1.
  static const AppCodeColors mocha = AppCodeColors(
    keyword: Color(0xFFCBA6F7),
    string: Color(0xFFA6E3A1),
    number: Color(0xFFFAB387),
    comment: Color(0xFFA6ADC8),
    punctuation: Color(0xFFA6ADC8),
  );

  /// Every role, for a contrast gate that must not miss one.
  List<Color> get all => [keyword, string, number, comment, punctuation];
}
