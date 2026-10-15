// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The golden matrix: every theme at 100% and 200% text scale, at both a
/// pointer-width and a compact-width viewport.
///
/// The width axis exists because [AppTouchTargets.of] falls back to the window
/// width, so every phone takes a branch (44pt rows, 48pt menu items, and a
/// menu-item type step from [AppText.ui] to [AppText.body]) that a
/// desktop-width-only matrix never renders at all.
///
/// The layout assertions (no overflow at any scale) run everywhere and are the
/// part that catches real regressions.
///
/// The pixel comparison is gated behind the compile-time flag
/// `--dart-define=SLIMM_GOLDENS=true`. Skia and font rendering differ between
/// machines, so images generated on a contributor's box would never match
/// CI's runner, and committing them would mean a permanently red build that
/// everyone learns to ignore. Reference images must come from the pinned
/// runner client-ci.yml itself uses: trigger its `update-golden-references`
/// job by hand (workflow_dispatch), download the `golden-references`
/// artifact it produces, and commit its contents into this directory's
/// `goldens/`. `client-ci.yml`'s own test step then turns the flag on by
/// itself, once it finds PNGs there; no further workflow edit is needed.
///
/// What these actually guard is the thing that breaks silently: text at 200%
/// overflowing its container. A layout that looks right at 100% and clips at
/// 200% is a real accessibility failure, and only a rendered comparison catches
/// it.
///
/// Not wired into `expectSettled` (`packages/app/test/support/mid_flight_
/// capture.dart`), and deliberately: [_sample] has no `ProviderScope`, no
/// `FutureProvider`, and no network fixture of any kind, so nothing in this
/// file can resolve after the frame that painted it. There is no mid-flight
/// state here to catch.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

/// The themes the matrix covers.
const _themes = <String, AppTokens>{
  'light': AppTokens.light,
  'dark': AppTokens.dark,
  'true_black': AppTokens.trueBlack,
};

/// Text scales. 2.0 is the accessibility ceiling the roadmap commits to.
const _scales = <String, double>{'100': 1.0, '200': 2.0};

/// The two input classes, named by width. 390x844 is a phone; 800x900 sits
/// above [kCompactWidth] and is the pointer case.
const _viewports = <String, Size>{
  'w800': Size(800, 900),
  'w390': Size(390, 844),
};

/// A representative slice of chrome: a header, a selected and unselected row,
/// and a body message. Enough surface that a token or spacing regression shows
/// up, without pulling in the whole app and its providers.
Widget _sample(AppTokens tokens) {
  return Builder(
    builder: (context) {
      return Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 52,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              decoration: BoxDecoration(
                color: tokens.surfaceRaised,
                border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
              ),
              child: Text(
                'slim-m',
                style: TextStyle(
                  color: tokens.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              color: tokens.accent.withValues(alpha: 0.12),
              child: Row(
                children: [
                  Icon(AppIcons.hash, size: 16, color: tokens.accent),
                  const SizedBox(width: AppSpacing.s12),
                  Expanded(
                    child: Text(
                      'general',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
              child: Row(
                children: [
                  Icon(AppIcons.voice, size: 16, color: tokens.textSecondary),
                  const SizedBox(width: AppSpacing.s12),
                  Expanded(
                    child: Text(
                      'lounge',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const _Controls(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Ada',
                      style: TextStyle(
                        color: tokens.textSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Text(
                      'A short message, long enough to wrap once.',
                      style: TextStyle(color: tokens.textPrimary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The four controls whose drawn size or type changes with density, laid out
/// the way a real settings body lays them out.
class _Controls extends StatelessWidget {
  const _Controls();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AppSpacing.s8,
        children: [
          AppListRow(label: 'Priya Raman', meta: 'admin'),
          AppMenuItem(label: 'Copy message link', leading: AppIcons.copy),
          Row(
            spacing: AppSpacing.s8,
            children: [
              AppIconButton(icon: AppIcons.add, semanticLabel: 'Add'),
              Expanded(
                child: AppButton(
                  label: 'Save changes',
                  variant: AppButtonVariant.primary,
                  full: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

void main() {
  for (final theme in _themes.entries) {
    for (final scale in _scales.entries) {
      for (final viewport in _viewports.entries) {
        final name =
            '${theme.key} at ${scale.key} percent, ${viewport.key} wide';
        testWidgets(name, (tester) async {
          tester.view.physicalSize = viewport.value;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            MediaQuery(
              // From the view, not a bare MediaQueryData: a fresh one reports
              // Size.zero, which reads as compact and hides the width axis.
              data: MediaQueryData.fromView(tester.view)
                  .copyWith(textScaler: TextScaler.linear(scale.value)),
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(
                  theme.key == 'light' ? Brightness.light : Brightness.dark,
                  theme.value,
                ),
                home: _sample(theme.value),
              ),
            ),
          );
          await tester.pumpAndSettle();

          /// No overflow at any scale. This is the assertion that matters most:
          /// clipped text at 200% is an accessibility failure, and it is
          /// invisible in a 100% screenshot.
          expect(tester.takeException(), isNull);

          // The width axis is only worth its runtime if it actually lands on
          // the other density, so pin that rather than trusting the size.
          final touch = viewport.value.width < kCompactWidth;
          expect(
            tester.getSize(find.byType(AppButton)).height,
            touch ? AppSizes.rowTouch : AppSizes.controlMd,
            reason: 'the $name pass must render at the density it claims',
          );
          // Past 100% the row grows to hold the scaled label rather than clipping it (AppListRow.heightFor), so only 100% pins the exact value.
          final fixedRowHeight =
              touch ? AppSizes.rowTouch : AppSizes.rowPointer;
          expect(
            tester.getSize(find.byType(AppListRow)).height,
            scale.value > 1 ? greaterThan(fixedRowHeight) : fixedRowHeight,
          );
          expect(
            tester.getSize(find.byType(AppMenuItem)).height,
            touch ? AppSizes.rowTouchMenu : AppSizes.controlMd,
          );

          // Pixel comparison only where the reference images were produced.
          if (const bool.fromEnvironment('SLIMM_GOLDENS')) {
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                'goldens/${theme.key}_${scale.key}_${viewport.key}.png',
              ),
            );
          }
        });
      }
    }
  }

  test('true black is genuinely black, not just dark', () {
    // The point of the OLED theme is the unlit pixel; anything above zero
    // defeats it, so this is worth asserting rather than eyeballing.
    expect(AppTokens.trueBlack.surfaceBase, const Color(0xFF000000));
    expect(
      AppTokens.trueBlack.surfaceBase.computeLuminance(),
      0.0,
      reason: 'a true-black base must emit no light',
    );
  });
}
