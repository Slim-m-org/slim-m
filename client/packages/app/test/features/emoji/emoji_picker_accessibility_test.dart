// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Accessibility coverage for the emoji picker: the search field and every
/// tile carry a name a screen reader can speak, a deployment's own emoji
/// announces its shortcode rather than a blank glyph, and the category /
/// result-count live region updates as the grid silently repaints.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_design_system/design_system.dart';

// A 1x1 transparent PNG, so Image.memory decodes rather than throwing.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

CustomEmoji _custom(String name) =>
    CustomEmoji(id: 'e-$name', name: name, uploaderId: 'u1', createdAt: 1);

// custom null leaves the list provider alone: an unfetchable, so empty, list.
Widget _harness(Widget child, {List<CustomEmoji>? custom}) => ProviderScope(
  overrides: [
    if (custom != null) customEmojiProvider.overrideWith((ref) => custom),
    customEmojiImageProvider.overrideWith((ref, id) => _png),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  testWidgets('the search field and a tile both have accessible names', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(EmojiPickerPanel(onSelect: (_) {}, onClose: () {})),
    );

    // Substring, not equality: AppInput also exposes its placeholder as the field's own hint, which merges into the same node.
    expect(find.bySemanticsLabel(RegExp('Search emoji')), findsOneWidget);
    // Many tiles carry "grinning" in their name, so any hit proves the tiles are named rather than anonymous glyphs.
    expect(
      find.bySemanticsLabel(RegExp('grinning', caseSensitive: false)),
      findsWidgets,
    );
  });

  testWidgets(
    "a deployment's own tile announces its shortcode, not a blank name",
    (tester) async {
      await tester.pumpWidget(
        _harness(
          EmojiPickerPanel(onSelect: (_) {}, onClose: () {}),
          custom: [_custom('party_parrot')],
        ),
      );

      expect(find.bySemanticsLabel(':party_parrot:'), findsOneWidget);
    },
  );

  testWidgets('switching category announces it as a live region', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(EmojiPickerPanel(onSelect: (_) {}, onClose: () {})),
    );

    final before = tester.widget<Semantics>(
      find.byKey(EmojiPickerPanel.liveRegionKey),
    );
    expect(before.properties.liveRegion, isTrue);
    expect(before.properties.label, 'Smileys and emotion emoji.');

    await tester.tap(find.byTooltip('Food and drink'));
    await tester.pump();

    final after = tester.widget<Semantics>(
      find.byKey(EmojiPickerPanel.liveRegionKey),
    );
    expect(after.properties.label, 'Food and drink emoji.');
  });

  testWidgets('a search with no matches announces so as the same live '
      'region', (tester) async {
    await tester.pumpWidget(
      _harness(EmojiPickerPanel(onSelect: (_) {}, onClose: () {})),
    );

    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pump();

    final region = tester.widget<Semantics>(
      find.byKey(EmojiPickerPanel.liveRegionKey),
    );
    expect(region.properties.label, 'No matches.');
  });
}
