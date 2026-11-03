// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Exporting the theme in use: its colours, and the personal background
/// picture when one is set, shrunk to the file's cap.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store_actions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

class _Probe extends ConsumerWidget {
  const _Probe(this.onRef);

  final void Function(WidgetRef ref) onRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onRef(ref);
    return const SizedBox();
  }
}

Future<ThemeDocument> _export(
  WidgetTester tester,
  List<Override> overrides,
  AppThemeChoice choice,
) async {
  SharedPreferences.setMockInitialValues({});
  late WidgetRef ref;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        meProvider.overrideWith(
          (ref) async => const api.Me(
            id: 'self',
            username: 'self',
            displayName: 'Self',
            createdAt: 0,
            permissions: 0,
          ),
        ),
        ...overrides,
      ],
      child: MaterialApp(home: _Probe((r) => ref = r)),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => ref.read(themeControllerProvider.notifier).select(choice),
  );
  final doc = await tester.runAsync(
    () => currentThemeDocument(ref, Brightness.dark),
  );
  return doc!;
}

Future<List<int>> _picture(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF336644),
  );
  final image = await rec.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('a preset exports as a file that parses back to it', (
    tester,
  ) async {
    final doc = await _export(tester, const [], AppThemeChoice.forest);

    expect(doc.base, 'forest');
    expect(doc.author, 'Self');
    expect(doc.picture, isNull);
    final back = parseThemeFile(doc.toJsonText()).document!;
    expect(back.toJson(), doc.toJson());
    expect(back.tokens.accent, AppTokens.forest.accent);
  });

  testWidgets('the personal background picture travels with the theme', (
    tester,
  ) async {
    final store = MemoryBackgroundImageStore();
    final bytes = (await tester.runAsync(() => _picture(2000, 1200)))!;
    await store.write(Uint8List.fromList(bytes));
    final doc = await _export(tester, [
      backgroundImageStoreProvider.overrideWithValue(store),
      appBackgroundControllerProvider.overrideWith(
        () => AppBackgroundController(
          const AppBackgroundSettings(
            hasImage: true,
            dim: 0.4,
            vignette: false,
            blur: 0.5,
          ),
        ),
      ),
    ], AppThemeChoice.dark);

    final picture = doc.picture!;
    expect(picture.dim, 0.4);
    expect(picture.vignette, isFalse);
    expect(picture.blur, 0.5);
    expect(picture.data!.length, lessThanOrEqualTo(themePictureMaxBytes));
    final back = parseThemeFile(doc.toJsonText()).document!;
    expect(back.picture!.data, picture.data);
  });
}
