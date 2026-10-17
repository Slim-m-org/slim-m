// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The busiest settings panes keep their section headers few: voice groups its
/// controls into four cards, appearance's display controls into two.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/display_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';

import '../voice/voice_settings_screen_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the voice pane has five section headers', (tester) async {
    await tester.pumpWidget(
      wrap(const VoiceSettingsBody(), overrides: ungatedSession()),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSectionHeader), findsNWidgets(5));
    expect(find.text('Devices'), findsOneWidget);
  });

  testWidgets('the appearance pane sits under three section headers', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const AppearanceSettingsSection()));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsSectionHeader), findsNWidgets(3));
    expect(find.byKey(DisplaySettingsSection.spacingSliderKey), findsOneWidget);
    expect(find.byKey(DisplaySettingsSection.scaleSliderKey), findsOneWidget);
  });
}
