// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Message density, group spacing and interface scale (decision 0062),
/// asserted as measured geometry and as persistence across a restart.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/display_density.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/widgets/author_profile_tap_target.dart';
import 'package:slimm_app/src/widgets/display_density_preview.dart';
import 'package:slimm_app/src/widgets/display_settings_section.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/widgets/ui_scale_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart';

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      userProfileProvider('author-1').overrideWith(
        (ref) async => const api.UserProfile(
          id: 'author-1',
          username: 'priya',
          displayName: 'Priya',
          createdAt: 0,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Widget _app(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

Widget _row() => MessageRow(
  message: message(),
  grouped: false,
  showNewDivider: false,
  knownUsernames: const {},
  actions: noActions,
  editing: false,
  callbacks: MessageRowCallbacks(
    onRetry: noop,
    onDiscard: noop,
    onPickReaction: (_) {},
    onReactionTap: (_) {},
    onVote: (_) {},
    onSubmitEdit: (_) {},
    onCancelEdit: noop,
  ),
);

/// Gap above the avatar and the avatar's own edge, measured from the render
/// tree.
Future<({double gap, double avatar})> _measureRow(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(_app(container, _row()));
  await tester.pumpAndSettle();
  final row = tester.getRect(find.byType(MessageRow));
  final avatar = tester.getRect(find.byType(AppAvatar).first);
  return (gap: avatar.top - row.top, avatar: avatar.height);
}

double _previewAvatarTop(WidgetTester tester) => tester
    .getTopLeft(
      find.descendant(
        of: find.byKey(DisplayDensityPreview.secondRowKey),
        matching: find.byType(AppAvatar),
      ),
    )
    .dy;

Finder _trackOf(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(Slider));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('density sets the gap above a group and the avatar step', (
    tester,
  ) async {
    final container = _container();
    final measured = <AppDensity, ({double gap, double avatar})>{};
    for (final density in AppDensity.values) {
      await container
          .read(messageDensityControllerProvider.notifier)
          .select(density);
      measured[density] = await _measureRow(tester, container);
    }

    expect(measured[AppDensity.compact]!.gap, AppDensity.compact.rowGap);
    expect(measured[AppDensity.normal]!.gap, AppDensity.normal.rowGap);
    expect(measured[AppDensity.spacious]!.gap, AppDensity.spacious.rowGap);
    expect(measured[AppDensity.compact]!.avatar, AppAvatarSize.s28);
    expect(measured[AppDensity.normal]!.avatar, AppAvatarSize.s40);
  });

  testWidgets('group spacing adds to the gap above a new group', (
    tester,
  ) async {
    final container = _container();
    await container.read(groupSpacingControllerProvider.notifier).select(12);

    final measured = await _measureRow(tester, container);

    expect(measured.gap, AppDensity.normal.rowGap + 12);
  });

  testWidgets('the compact avatar keeps a 44dp touch target', (tester) async {
    final container = _container();
    await container
        .read(messageDensityControllerProvider.notifier)
        .select(AppDensity.compact);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(container, _row()));
    await tester.pumpAndSettle();

    final avatar = tester.getRect(find.byType(AppAvatar).first);
    final inside = avatar.topLeft + const Offset(10, 40);

    final hit = tester.hitTestOnBinding(inside);

    final listener = find
        .descendant(
          of: find.byType(AuthorProfileTapTarget).first,
          matching: find.byType(Listener),
        )
        .first
        .evaluate()
        .single
        .renderObject;
    expect(hit.path.any((entry) => entry.target == listener), isTrue);
    expect(inside.dy - avatar.top, greaterThan(AppAvatarSize.s28));
    expect(inside.dy - avatar.top, lessThan(AppSizes.rowTouch));
  });

  testWidgets('choices survive a restart and are clamped on restore', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      messageDensityKey: 'compact',
      groupSpacingKey: 9,
      uiScaleKey: 400,
    });
    final container = _container();
    for (final restorable in [
      container.read(messageDensityControllerProvider.notifier),
      container.read(groupSpacingControllerProvider.notifier),
      container.read(uiScaleControllerProvider.notifier),
    ]) {
      await restorable.restore();
    }

    expect(
      container.read(messageDensityControllerProvider),
      AppDensity.compact,
    );
    expect(container.read(groupSpacingControllerProvider), 8);
    expect(container.read(uiScaleControllerProvider), uiScaleMax);
  });

  testWidgets('the settings controls drive the providers and the preview', (
    tester,
  ) async {
    final container = _container();
    await tester.pumpWidget(_app(container, const DisplaySettingsSection()));
    await tester.pumpAndSettle();

    final before = _previewAvatarTop(tester);
    await tester.tapAt(
      tester
              .getRect(_trackOf(DisplaySettingsSection.spacingSliderKey))
              .centerRight -
          const Offset(2, 0),
    );
    await tester.pumpAndSettle();

    expect(container.read(groupSpacingControllerProvider), 16);
    final after = _previewAvatarTop(tester);
    expect(after - before, 16);

    await tester.tapAt(
      tester
              .getRect(_trackOf(DisplaySettingsSection.scaleSliderKey))
              .centerLeft +
          const Offset(2, 0),
    );
    await tester.pumpAndSettle();
    expect(container.read(uiScaleControllerProvider), uiScaleMin);
  });

  testWidgets('interface scale lays out at size over scale and hit-tests '
      'in window coordinates', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var taps = 0;
    Size? laidOut;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: UiScaleFrame(
          scale: 1.25,
          child: LayoutBuilder(
            builder: (context, constraints) {
              laidOut = constraints.biggest;
              return Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox(width: 80, height: 80),
                ),
              );
            },
          ),
        ),
      ),
    );

    expect(laidOut, const Size(800, 640));
    expect(
      tester.getRect(find.byType(GestureDetector)).size,
      const Size(100, 100),
    );
    await tester.tapAt(const Offset(95, 95));
    expect(taps, 1);
  });

  test('scaleMediaQuery divides lengths so breakpoints see the effective '
      'width', () {
    const data = MediaQueryData(
      size: Size(1000, 800),
      padding: EdgeInsets.only(top: 40),
    );

    final scaled = scaleMediaQuery(data, 1.25);

    expect(scaled.size, const Size(800, 640));
    expect(scaled.padding.top, 32);
    expect(scaleMediaQuery(data, 1), same(data));
  });
}
