// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `SettingsEntityRow` replaced five independent hand-rolled copies of one
/// shape (roles, invites, emoji, removed members, categories). The copies had
/// already drifted in two ways worth pinning here, because both would drift
/// again the moment somebody hand-rolls a sixth.
///
/// The error banner sat *inside* the card in four of them and *above* it in
/// `invites_screen`, so a failed revoke pushed the whole list down rather than
/// annotating the row it belonged to.
///
/// And only `roles_screen` reserved empty action slots, with its own comment
/// explaining why: without it, a row offering fewer buttons slides its
/// remaining ones right and no two rows in the list line up.
///
/// `actions` used to accept `List<Widget>`, and two call sites wrapped their
/// own reserved-slot row around it to get nullable elements, nesting one
/// inside the other; this test enshrined that double-wrap as the documented
/// shape until it was caught. `actions` is `List<Widget?>` now, passed flat.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_entity_row.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

const _row = Key('row');

/// A row in a settings card, as a catalog lists it, with three actions.
Widget _carded({bool dense = false, bool touch = false, Widget? badge}) =>
    _harness(
      AppTouchTargets(
        enabled: touch,
        child: SettingsSectionCard(
          children: [
            SettingsEntityRow(
              key: _row,
              dense: dense,
              headline: 'airhorn',
              badge: badge,
              actions: [
                for (final icon in [
                  AppIcons.play,
                  AppIcons.edit,
                  AppIcons.delete,
                ])
                  AppIconButton(
                    key: ValueKey(icon),
                    icon: icon,
                    semanticLabel: '$icon',
                    onPressed: () {},
                  ),
              ],
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('a dense row tightens its padding inside a card too', (
    tester,
  ) async {
    await tester.pumpWidget(_carded());
    final roomy = tester.getSize(find.byKey(_row)).height;
    await tester.pumpWidget(_carded(dense: true));
    final dense = tester.getSize(find.byKey(_row)).height;

    expect(roomy, AppSizes.rowPointer + 20);
    expect(dense, AppSizes.rowPointer + AppSpacing.s4 * 2);
  });

  testWidgets('a caption badge sits on the headline baseline', (tester) async {
    await tester.pumpWidget(
      _carded(badge: const Text('1.4 s', style: AppText.caption)),
    );
    double baseline(String text) {
      final finder = find.text(text);
      final box = tester.renderObject<RenderBox>(finder);
      return tester.getTopLeft(finder).dy +
          box.getDryBaseline(box.constraints, TextBaseline.alphabetic)!;
    }

    expect(baseline('1.4 s'), moreOrLessEquals(baseline('airhorn')));
  });

  testWidgets('pointer actions keep a gap; touch ones end on the inset', (
    tester,
  ) async {
    Rect slot(IconData icon) => tester.getRect(find.byKey(ValueKey(icon)));

    await tester.pumpWidget(_carded(dense: true));
    expect(slot(AppIcons.edit).left - slot(AppIcons.play).right, AppSpacing.s4);
    expect(
      slot(AppIcons.delete).left - slot(AppIcons.edit).right,
      AppSpacing.s4,
    );

    await tester.pumpWidget(_carded(dense: true, touch: true));
    final visibleRight =
        slot(AppIcons.delete).right - (AppSizes.rowTouch - AppSizes.icon28) / 2;
    expect(
      tester.getRect(find.byKey(_row)).right - visibleRight,
      AppCardRowScope.inset,
      reason: 'the trash outline, not its wider tap slot, ends on the inset',
    );
  });

  testWidgets('the inline failure annotates the row, below its own content', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const SettingsEntityRow(
          headline: 'weekend-invite',
          error: 'Could not revoke the invite.',
        ),
      ),
    );

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(
      tester.getRect(find.byType(AppErrorState)).top,
      greaterThan(tester.getRect(find.text('weekend-invite')).bottom),
      reason:
          'invites_screen put this above the card, which shoved every row '
          'below it down the page instead of marking the one that failed',
    );
  });

  testWidgets('no failure means no banner and no reserved space', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const SettingsEntityRow(headline: 'weekend-invite')),
    );

    expect(find.byType(AppErrorState), findsNothing);
  });

  testWidgets('detail lines render under the headline, in the order given', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const SettingsEntityRow(
          headline: 'weekend-invite',
          details: [
            SettingsEntityDetail('3/10 uses'),
            SettingsEntityDetail('Grants moderator'),
          ],
        ),
      ),
    );

    final headline = tester.getRect(find.text('weekend-invite'));
    final first = tester.getRect(find.text('3/10 uses'));
    final second = tester.getRect(find.text('Grants moderator'));

    expect(first.top, greaterThan(headline.top));
    expect(second.top, greaterThan(first.top));
  });

  testWidgets('derived metadata elides, but text a person wrote wraps', (
    tester,
  ) async {
    const reason =
        'Posted an invite link to another, unrelated Space in '
        'three channels after being asked to stop';

    await tester.pumpWidget(
      _harness(
        const SizedBox(
          width: 300,
          child: SettingsEntityRow(
            headline: 'Grace Hopper',
            details: [
              SettingsEntityDetail('@grace'),
              SettingsEntityDetail(reason, wrap: true),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.widget<Text>(find.text(reason)).overflow,
      isNot(TextOverflow.ellipsis),
      reason:
          'this shipped for one capture as "Posted an invite link to another, '
          'unrelat..." - the one line the moderator opened the screen to read',
    );
    expect(
      tester.widget<Text>(find.text('@grace')).overflow,
      TextOverflow.ellipsis,
      reason:
          'a handle is short by construction and keeps the list even when '
          'clipped, so the default stays elide',
    );
  });

  testWidgets('a null action reserves its slot, so two rows offering '
      'different buttons still line up', (tester) async {
    Widget row(bool canDelete) => SettingsEntityRow(
      headline: canDelete ? 'moderator' : '@everyone',
      actions: [
        AppIconButton(
          icon: AppIcons.edit,
          semanticLabel: 'Edit',
          onPressed: () {},
        ),
        if (canDelete)
          AppIconButton(
            icon: AppIcons.delete,
            semanticLabel: 'Delete',
            onPressed: () {},
          )
        else
          null,
      ],
    );

    await tester.pumpWidget(_harness(row(true)));
    final withDelete = tester.getRect(find.byIcon(AppIcons.edit));

    await tester.pumpWidget(_harness(row(false)));
    final withoutDelete = tester.getRect(find.byIcon(AppIcons.edit));

    expect(
      withoutDelete.left,
      withDelete.left,
      reason:
          'the edit button must land at the same x whether or not the row '
          'also offers delete - roles_screen had to hand-roll this and every '
          'other list simply did not have it',
    );
  });

  testWidgets('a pointer over the row tints it, animated rather than snapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const SettingsEntityRow(headline: 'weekend-invite')),
    );
    await tester.pumpAndSettle();

    Color? fill() {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SettingsEntityRow),
              matching: find.byType(Container),
            )
            .first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    expect(fill(), Colors.transparent);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(SettingsEntityRow)));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final target = AppTokens.light.surfaceSunken;
    final mid = fill();
    expect(mid, isNot(Colors.transparent), reason: 'the tint has set off');
    expect(mid, isNot(target), reason: 'and has not already arrived');
    await tester.pumpAndSettle();
    expect(fill(), target);
  });

  testWidgets('labelled actions on a phone sit under the text, not beside it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        SettingsEntityRow(
          key: _row,
          headline: 'Grace Hopper',
          details: const [SettingsEntityDetail('Posted an invite link')],
          actions: [
            AppButton(label: 'Let back in', onPressed: () {}),
            AppButton(label: 'Delete', onPressed: () {}),
          ],
        ),
      ),
    );
    final text = tester.getRect(find.text('Posted an invite link'));
    final button = tester.getRect(
      find.ancestor(
        of: find.text('Let back in'),
        matching: find.byWidgetPredicate((w) => w is AppButton),
      ),
    );
    expect(button.top - text.bottom, greaterThanOrEqualTo(AppSpacing.s8));
    final delete = tester.getRect(find.text('Delete'));
    expect(delete.left - button.right, greaterThanOrEqualTo(AppSpacing.s8));
  });
}
