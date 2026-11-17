// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space section of the Themes gallery reads the store fresh on open: the
/// list is held all session by the applied theme, so a theme another member
/// published meanwhile was missing until Settings had been closed long enough.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/theme_store.dart';

import 'theme_gallery_rig.dart';

void main() {
  testWidgets('opening Themes shows a theme published since the store loaded', (
    tester,
  ) async {
    final rig = GalleryRig(themes: []);
    rig.container.listen(spaceThemesProvider, (_, _) {});
    await rig.container.read(spaceThemesProvider.future);
    rig.themes.add(stored('moss', 'Hana Moss', author: 'hana'));

    await rig.pump(tester);
    await settleGallery(tester);

    expect(rig.calls.where((c) => c == 'GET /space/themes'), hasLength(2));
    expect(find.byKey(const Key('theme-store-moss')), findsOneWidget);
    expect(find.byKey(const Key('theme-store-empty')), findsNothing);
  });

  testWidgets('an empty store says what shows there, not what to do', (
    tester,
  ) async {
    final rig = GalleryRig(themes: []);
    await rig.pump(tester);

    expect(find.text('No shared themes yet.'), findsOneWidget);
    expect(
      find.text('Themes members publish from Mine show up here.'),
      findsOneWidget,
    );
  });
}
