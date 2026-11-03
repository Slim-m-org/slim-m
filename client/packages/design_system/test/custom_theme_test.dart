// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

ThemeDocument _of(String base, {ThemePicture? picture}) => ThemeDocument.of(
      themeBases[base]!,
      name: base,
      author: 'me',
      base: base,
      brightness: base == 'light' ? Brightness.light : Brightness.dark,
      picture: picture,
    );

Map<String, dynamic> _json(String base) => _of(base).toJson();

void main() {
  for (final base in themeBases.keys) {
    test('the built-in $base theme passes its own file checks', () {
      final parsed = parseThemeFile(_of(base).toJsonText());
      expect(parsed.problems, isEmpty);
      expect(parsed.document!.toJson(), _of(base).toJson());
      expect(parsed.document!.tokens.status, themeBases[base]!.status);
    });
  }

  test('a document round-trips, picture and effect included', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final doc = ThemeDocument.of(
      AppTokens.halloween,
      name: 'Spooky',
      author: 'me',
      base: 'halloween',
      brightness: Brightness.dark,
      picture: ThemePicture(dim: 0.6, vignette: false, blur: 0.25, data: bytes),
    );
    final back = parseThemeFile(doc.toJsonText()).document!;
    expect(back.name, 'Spooky');
    expect(back.effect, AppBackdrop.halloweenWebs);
    expect(back.picture!.data, bytes);
    expect(back.picture!.dim, 0.6);
    expect(back.picture!.vignette, isFalse);
    expect(back.tokens.backdrop, AppBackdrop.halloweenWebs);
  });

  test('a theme without an effect clears the preset backdrop', () {
    final json = _json('halloween');
    (json['backdrop'] as Map).remove('effect');
    json.remove('backdrop');
    expect(parseThemeJson(json).document!.tokens.backdrop, isNull);
  });

  group('validation names each problem', () {
    String problems(Map<String, dynamic> json) =>
        parseThemeJson(json).problems.join('|');

    test('not JSON, and not a theme', () {
      expect(parseThemeFile('{nope').problems, isNotEmpty);
      expect(parseThemeFile('[]').problems, isNotEmpty);
    });

    test('missing, unknown and malformed tokens', () {
      final json = _json('dark');
      final tokens = json['tokens'] as Map<String, dynamic>;
      tokens.remove('accent');
      tokens['bogus'] = '#000000';
      tokens['surfaceBase'] = 'red';
      tokens['accentFill'] = '#80AABBCC';
      final text = problems(json);
      expect(text, contains('Missing token accent'));
      expect(text, contains('Unknown token bogus'));
      expect(text, contains('surfaceBase is not a valid colour'));
      expect(text, contains('accentFill is not a valid colour'));
    });

    test('low contrast text', () {
      final json = _json('dark');
      (json['tokens'] as Map<String, dynamic>)['textPrimary'] = '#1C2027';
      expect(
          problems(json), contains('textPrimary on surfaceBase is below 4.5'));
    });

    test('wrong format, base, brightness, name and extra keys', () {
      final json = _json('dark')
        ..['format'] = 'other'
        ..['base'] = 'neon'
        ..['brightness'] = 'grey'
        ..['name'] = ' '
        ..['extra'] = 1;
      final text = problems(json);
      expect(text, contains('Expected format'));
      expect(text, contains('base must be one of'));
      expect(text, contains('brightness must be'));
      expect(text, contains('name must be'));
      expect(text, contains('Unknown key extra'));
    });

    test('a backdrop with an unknown effect or out-of-range picture settings',
        () {
      final json = _json('dark')
        ..['backdrop'] = {
          'effect': 'snow',
          'picture': {'dim': 2, 'vignette': true, 'blur': 0},
        };
      final text = problems(json);
      expect(text, contains('Unknown backdrop effect snow'));
      expect(text, contains('picture dim and blur'));
    });

    test('picture data that is not base64', () {
      final json = _json('dark')
        ..['backdrop'] = {
          'picture': {'data': '!!', 'dim': 0.5, 'vignette': true, 'blur': 0},
        };
      expect(problems(json), contains('base64'));
    });
  });

  test('toJson matches the wire shape the server stores', () {
    final json = jsonDecode(_of('forest').toJsonText()) as Map<String, dynamic>;
    expect(json['format'], 'slimm-theme');
    expect((json['tokens'] as Map).length, 19);
  });
}
