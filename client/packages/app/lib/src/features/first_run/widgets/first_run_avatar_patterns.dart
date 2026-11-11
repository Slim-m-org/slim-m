// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile step's no-upload option: initials, or a generated pattern.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/run_guarded.dart';
import '../../members/providers/member_actions.dart';
import '../../members/widgets/user_avatar.dart';
import '../../settings/widgets/settings_section_header.dart';
import 'avatar_patterns.dart';

/// How a pattern becomes PNG bytes; a test swaps it to encode on real time.
final avatarPatternRendererProvider = Provider<PatternRenderer>(
  (ref) => renderPatternPng,
);

/// Null stands for the initials avatar, which is no picture at all.
typedef _Choice = AvatarPattern?;

class FirstRunAvatarPatterns extends ConsumerStatefulWidget {
  const FirstRunAvatarPatterns({super.key});

  @override
  ConsumerState<FirstRunAvatarPatterns> createState() =>
      _FirstRunAvatarPatternsState();
}

class _FirstRunAvatarPatternsState extends ConsumerState<FirstRunAvatarPatterns>
    with GuardedActionState<FirstRunAvatarPatterns> {
  _Choice _picked;
  _Choice _failed;
  var _busy = false;

  Future<void> _choose(_Choice choice) async {
    final me = ref.read(meProvider).valueOrNull;
    if (me == null || _busy) return;
    final base = Theme.of(context).extension<AppTokens>()!.accentFill;
    final actions = ref.read(memberActionsProvider);
    final render = ref.read(avatarPatternRendererProvider);
    clearActionError();
    setState(() {
      _busy = true;
      _failed = null;
    });
    final ok = await guard(
      whatFailed: 'set your picture',
      action: () async {
        if (choice == null) return actions.deleteAvatar();
        final png = await render(choice, accountId: me.id, base: base);
        await actions.uploadAvatar(png);
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _picked = choice;
      } else {
        _failed = choice;
      }
    });
    if (ok) ref.invalidate(meProvider);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).valueOrNull;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return SettingsSectionCard(
      title: 'Or pick a pattern',
      description: 'Made from your account, in the theme colours.',
      topGap: kDenseSectionTopGap,
      children: [
        SettingsCardBlock(
          children: [
            Wrap(
              spacing: AppSpacing.s8,
              runSpacing: AppSpacing.s8,
              children: [
                _Tile(
                  label: 'Use my initials',
                  selected: _picked == null && !_busy && _failed == null,
                  onTap: me == null ? null : () => unawaited(_choose(null)),
                  child: UserAvatar(
                    userId: null,
                    name: me?.displayName ?? '',
                    size: AppAvatarSize.s44,
                  ),
                ),
                for (final pattern in AvatarPattern.values)
                  _Tile(
                    label: 'Use the ${pattern.name} pattern',
                    selected: _picked == pattern,
                    onTap: me == null
                        ? null
                        : () => unawaited(_choose(pattern)),
                    child: ClipOval(
                      child: CustomPaint(
                        size: const Size.square(AppAvatarSize.s44),
                        painter: AvatarPatternPainter(
                          pattern: pattern,
                          seed: patternSeed(me?.id ?? ''),
                          base: tokens.accentFill,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (_busy)
              const Align(
                alignment: Alignment.centerLeft,
                child: AppSpinner(size: AppSpinnerSize.md),
              ),
            if (actionError != null)
              AppErrorState(
                message: '$actionError Try again, or keep your initials.',
                onRetry: () => unawaited(_choose(_failed)),
                onDismiss: clearActionError,
              ),
          ],
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return FocusableTapTarget(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      ringRadius: AppRadii.full,
      builder: (context, focused, hovered) => Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? tokens.accentFill : Colors.transparent,
            width: 2,
          ),
        ),
        child: ExcludeSemantics(child: child),
      ),
    );
  }
}
