// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme file (decision 0106): a full theme that can be exported, shared
/// through the Space store and applied on another device.
///
/// The checks mirror the server's `space_theme.rs`; a file that passes one
/// must pass the other.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';

import 'app_tokens.dart';
import 'colour_contrast.dart';

const themeFileFormat = 'slimm-theme';
const themeFileVersion = 1;
const themeNameMaxChars = 40;
const themePictureMaxBytes = 2 * 1024 * 1024;

/// The built-in presets a file names as its `base`, in the order Appearance lists them.
const themeBases = <String, AppTokens>{
  'dark': AppTokens.dark,
  'light': AppTokens.light,
  'trueBlack': AppTokens.trueBlack,
  'catppuccin': AppTokens.mocha,
  'softDark': AppTokens.soft,
  'forest': AppTokens.forest,
  'halloween': AppTokens.halloween,
};

const _tokenKeys = [
  'surfaceSunken',
  'surfaceBase',
  'surfaceRaised',
  'borderSubtle',
  'borderStrong',
  'textPrimary',
  'textSecondary',
  'textDisabled',
  'accent',
  'accentFill',
  'accentOn',
  'accentSoft',
  'accentRing',
  'focusRing',
  'dangerText',
  'dangerBorder',
  'warnText',
  'warnSoft',
  'stripe',
];
const _mayHaveAlpha = {'accentRing', 'warnSoft', 'stripe'};
const _surfaces = ['surfaceSunken', 'surfaceBase', 'surfaceRaised'];

/// The picture settings of 0104, with the bytes when a file carries them.
class ThemePicture {
  const ThemePicture({
    required this.dim,
    required this.vignette,
    required this.blur,
    this.data,
  });

  final double dim;
  final bool vignette;
  final double blur;

  /// Null in a store listing, which carries `present: true` instead.
  final Uint8List? data;
}

class ThemeDocument {
  const ThemeDocument({
    required this.name,
    required this.author,
    required this.base,
    required this.brightness,
    required this.colours,
    this.effect,
    this.picture,
  });

  final String name;
  final String author;
  final String base;
  final Brightness brightness;
  final Map<String, Color> colours;
  final AppBackdrop? effect;
  final ThemePicture? picture;

  /// The preset's tokens with this file's colours and backdrop effect.
  AppTokens get tokens {
    final p = themeBases[base]!;
    Color c(String key) => colours[key]!;
    return AppTokens(
      surfaceSunken: c('surfaceSunken'),
      surfaceBase: c('surfaceBase'),
      surfaceRaised: c('surfaceRaised'),
      borderSubtle: c('borderSubtle'),
      borderStrong: c('borderStrong'),
      textPrimary: c('textPrimary'),
      textSecondary: c('textSecondary'),
      textDisabled: c('textDisabled'),
      accent: c('accent'),
      accentFill: c('accentFill'),
      accentOn: c('accentOn'),
      accentSoft: c('accentSoft'),
      accentRing: c('accentRing'),
      focusRing: c('focusRing'),
      status: p.status,
      dangerText: c('dangerText'),
      dangerBorder: c('dangerBorder'),
      warnText: c('warnText'),
      warnSoft: c('warnSoft'),
      stripe: c('stripe'),
      code: p.code,
      backdrop: effect,
    );
  }

  /// A document describing [tokens], for exporting the theme in use.
  factory ThemeDocument.of(
    AppTokens tokens, {
    required String name,
    required String author,
    required String base,
    required Brightness brightness,
    ThemePicture? picture,
  }) =>
      ThemeDocument(
        name: name,
        author: author,
        base: base,
        brightness: brightness,
        colours: {
          'surfaceSunken': tokens.surfaceSunken,
          'surfaceBase': tokens.surfaceBase,
          'surfaceRaised': tokens.surfaceRaised,
          'borderSubtle': tokens.borderSubtle,
          'borderStrong': tokens.borderStrong,
          'textPrimary': tokens.textPrimary,
          'textSecondary': tokens.textSecondary,
          'textDisabled': tokens.textDisabled,
          'accent': tokens.accent,
          'accentFill': tokens.accentFill,
          'accentOn': tokens.accentOn,
          'accentSoft': tokens.accentSoft,
          'accentRing': tokens.accentRing,
          'focusRing': tokens.focusRing,
          'dangerText': tokens.dangerText,
          'dangerBorder': tokens.dangerBorder,
          'warnText': tokens.warnText,
          'warnSoft': tokens.warnSoft,
          'stripe': tokens.stripe,
        },
        effect: tokens.backdrop,
        picture: picture,
      );

  Map<String, dynamic> toJson() => {
        'format': themeFileFormat,
        'version': themeFileVersion,
        'name': name,
        'author': author,
        'base': base,
        'brightness': brightness == Brightness.light ? 'light' : 'dark',
        'tokens': {
          for (final key in _tokenKeys)
            key: _hex(colours[key]!, _mayHaveAlpha.contains(key)),
        },
        if (effect != null || picture != null)
          'backdrop': {
            'effect': effect?.name,
            if (picture != null)
              'picture': {
                if (picture!.data != null) 'data': base64Encode(picture!.data!),
                'dim': picture!.dim,
                'vignette': picture!.vignette,
                'blur': picture!.blur,
              },
          },
      };

  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// The outcome of reading a file: a document, or every problem found.
class ThemeParse {
  const ThemeParse.ok(ThemeDocument this.document) : problems = const [];
  const ThemeParse.failed(this.problems) : document = null;

  final ThemeDocument? document;
  final List<String> problems;
}

String _hex(Color c, bool alpha) {
  final v = c.toARGB32();
  final rgb = (v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  if (!alpha) return '#$rgb';
  return '#${(v >> 24).toRadixString(16).padLeft(2, '0').toUpperCase()}$rgb';
}

Color? _parseColour(Object? text, bool alphaOk) {
  if (text is! String || !text.startsWith('#')) return null;
  final digits = text.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(digits)) return null;
  if (digits.length == 6) {
    return Color(0xFF000000 | int.parse(digits, radix: 16));
  }
  if (digits.length == 8 && alphaOk) return Color(int.parse(digits, radix: 16));
  return null;
}

ThemeParse parseThemeFile(String text) {
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } on FormatException {
    return const ThemeParse.failed(['The file is not valid JSON.']);
  }
  return parseThemeJson(raw);
}

ThemeParse parseThemeJson(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    return const ThemeParse.failed(['The file is not a theme.']);
  }
  final problems = <String>[];
  const known = {
    'format',
    'version',
    'name',
    'author',
    'base',
    'brightness',
    'tokens',
    'backdrop'
  };
  for (final key in raw.keys.where((k) => !known.contains(k))) {
    problems.add('Unknown key $key.');
  }
  if (raw['format'] != themeFileFormat || raw['version'] != themeFileVersion) {
    problems.add('Expected format $themeFileFormat version $themeFileVersion.');
  }
  final name = _text(raw['name'], 'name', 1, problems);
  final author = _text(raw['author'] ?? '', 'author', 0, problems);
  final base = raw['base'];
  if (base is! String || !themeBases.containsKey(base)) {
    problems.add('base must be one of ${themeBases.keys.join(', ')}.');
  }
  final brightness = switch (raw['brightness']) {
    'light' => Brightness.light,
    'dark' => Brightness.dark,
    _ => null,
  };
  if (brightness == null) problems.add('brightness must be light or dark.');
  final colours = _colours(raw['tokens'], problems);
  if (colours != null && problems.isEmpty) _contrast(colours, problems);
  final backdrop = _backdrop(raw['backdrop'], problems);
  if (problems.isNotEmpty) return ThemeParse.failed(problems);
  return ThemeParse.ok(
    ThemeDocument(
      name: name!,
      author: author!,
      base: base as String,
      brightness: brightness!,
      colours: colours!,
      effect: backdrop.$1,
      picture: backdrop.$2,
    ),
  );
}

String? _text(Object? value, String field, int min, List<String> problems) {
  if (value is! String) {
    problems.add('$field must be text.');
    return null;
  }
  final length = value.trim().runes.length;
  if (length < min || length > themeNameMaxChars) {
    problems.add('$field must be $min to $themeNameMaxChars characters.');
  }
  return value.trim();
}

Map<String, Color>? _colours(Object? raw, List<String> problems) {
  if (raw is! Map<String, dynamic>) {
    problems.add('tokens must be an object.');
    return null;
  }
  for (final key in raw.keys.where((k) => !_tokenKeys.contains(k))) {
    problems.add('Unknown token $key.');
  }
  final colours = <String, Color>{};
  for (final key in _tokenKeys) {
    if (!raw.containsKey(key)) {
      problems.add('Missing token $key.');
      continue;
    }
    final colour = _parseColour(raw[key], _mayHaveAlpha.contains(key));
    if (colour == null) {
      problems.add('Token $key is not a valid colour.');
    } else {
      colours[key] = colour;
    }
  }
  return colours;
}

void _contrast(Map<String, Color> c, List<String> problems) {
  void floor(String fg, String bg, double min) {
    if (contrastRatio(c[fg]!, c[bg]!) < min) {
      problems.add('$fg on $bg is below $min:1.');
    }
  }

  for (final surface in _surfaces) {
    for (final text in [
      'textPrimary',
      'textSecondary',
      'accent',
      'dangerText',
      'warnText'
    ]) {
      floor(text, surface, 4.5);
    }
    floor('borderStrong', surface, 3);
  }
  floor('accentOn', 'accentFill', 4.5);
  floor('accent', 'accentSoft', 4.5);
  final base = c['surfaceBase']!;
  if (contrastRatio(c['textDisabled']!, base) >=
      contrastRatio(c['textSecondary']!, base)) {
    problems.add('textDisabled must be quieter than textSecondary.');
  }
}

(AppBackdrop?, ThemePicture?) _backdrop(Object? raw, List<String> problems) {
  if (raw == null) return (null, null);
  if (raw is! Map<String, dynamic>) {
    problems.add('backdrop must be an object.');
    return (null, null);
  }
  AppBackdrop? effect;
  final name = raw['effect'];
  if (name != null) {
    effect = AppBackdrop.values.where((e) => e.name == name).firstOrNull;
    if (effect == null) problems.add('Unknown backdrop effect $name.');
  }
  final picture = raw['picture'];
  if (picture == null) return (effect, null);
  if (picture is! Map<String, dynamic>) {
    problems.add('picture must be an object.');
    return (effect, null);
  }
  final dim = picture['dim'];
  final blur = picture['blur'];
  final vignette = picture['vignette'];
  if (dim is! num ||
      blur is! num ||
      vignette is! bool ||
      dim < 0 ||
      dim > 1 ||
      blur < 0 ||
      blur > 1) {
    problems.add(
        'picture dim and blur must be between 0 and 1, vignette true or false.');
    return (effect, null);
  }
  Uint8List? data;
  final text = picture['data'];
  if (text is String) {
    try {
      data = base64Decode(text);
    } on FormatException {
      problems.add('picture data must be base64.');
    }
    if (data != null && (data.isEmpty || data.length > themePictureMaxBytes)) {
      problems.add('picture must be 1 byte to 2 MiB.');
    }
  }
  return (
    effect,
    ThemePicture(
        dim: dim.toDouble(),
        vignette: vignette,
        blur: blur.toDouble(),
        data: data),
  );
}
