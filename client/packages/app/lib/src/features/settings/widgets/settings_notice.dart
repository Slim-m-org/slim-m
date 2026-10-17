// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a settings surface shows when it has nothing to show, and why.
///
/// The per-screen review found the same root cause behind two findings at two
/// scales: "a section with nothing to show renders as literal absence rather
/// than a stated reason for the absence". At screen scale that was
/// [SpaceSettingsSection] returning `SizedBox.shrink()` as an entire screen
/// body, so a caller holding none of its gating bits - reachable not only by
/// a stray URL but by a live permission revocation while the screen is open -
/// watched it collapse to a bare app bar over blank white. At field scale it
/// was a removal with no stated reason rendering no line at all, two lines
/// beside a sibling card's three, which reads as a rendering gap rather than
/// as a deliberate absence.
///
/// This is not a new invention: it is the shape `DebugLogScreen`'s own empty
/// state already had (an icon, a plain sentence, a caption explaining what
/// would put something here), lifted out so the cases that never got that
/// treatment can have it. The list-shaped empty states in this area already
/// read correctly through [AppAsyncView]'s own `emptyMessage`, and this
/// deliberately matches its type step and colour so a screen that has nothing
/// for you reads the same whether the nothing is a list, a screen, or a field.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// A stated reason for an absence, centred in whatever space it is given.
///
/// [message] is the plain sentence: what is true, not what failed. This is
/// deliberately never an [AppErrorState] - nothing has gone wrong, and
/// dressing an ordinary "you do not have access to anything here" as a
/// failure invites a retry that would do nothing.
class SettingsNotice extends StatelessWidget {
  const SettingsNotice({
    super.key,
    required this.message,
    this.detail,
    this.icon,
  });

  final String message;

  /// A second line saying what would put something here, when there is a
  /// useful answer. Omitted where there is not.
  final String? detail;

  /// Defaults to the neutral info glyph. A caller passes one only where a
  /// more specific glyph genuinely says more.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? AppIcons.info,
              size: AppSizes.icon24,
              color: tokens.textSecondary,
            ),
            const SizedBox(height: AppSpacing.s12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
            if (detail != null) ...[
              const SizedBox(height: AppSpacing.s4),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The field-scale version: one muted line standing in for a value that is
/// genuinely absent, inline where the value would have been.
///
/// Distinct from [SettingsNotice] rather than a variant of it because the two
/// answer different questions. A notice explains why a surface is empty and
/// owns the space it sits in; this states that one optional field has no
/// value, in the row's own flow, so a card with no reason keeps the same line
/// count as one that has a reason instead of silently losing a line.
class SettingsAbsentValue extends StatelessWidget {
  const SettingsAbsentValue(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      text,
      style: AppText.caption.copyWith(
        color: tokens.textSecondary,
        fontStyle: FontStyle.italic,
      ),
    );
  }
}
