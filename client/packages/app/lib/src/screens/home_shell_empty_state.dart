// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the conversation pane shows with no channel chosen.
///
/// Split out of `home_shell.dart` once it grew the shortcut list below and
/// pushed that file past its 500-line hard cap - the seam `channel_rail`'s
/// own splits already use, and a real one: everything here is the empty
/// pane, while what remains owns the shell around it.
///
/// The list exists because the pane is otherwise a sentence in the middle of
/// a large empty area on desktop, which is what prompted "could we take up
/// the empty editor space, like vscode does".
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// The first thing a fresh desktop sign-in lands on, so it carries the same
/// visual weight `ChannelStartHeader` gives the functionally identical
/// "nothing here yet" case, rather than a single small line of grey text.
/// The Ctrl+K hint drops on a touch layout, the same rule the rail's own
/// search field hint already follows - no finger can press it.
class NoChannelSelected extends StatelessWidget {
  const NoChannelSelected({super.key});

  @override
  Widget build(BuildContext context) => const _NothingSelected();
}

class _NothingSelected extends StatelessWidget {
  const _NothingSelected();

  /// The shortcuts worth showing someone looking at an empty pane, in the
  /// order a person meets them. Read from the shared table rather than
  /// written out, so a remap moves these with it and the hint cannot drift
  /// from the key that actually works.
  static const _shown = [
    AppAction.quickSwitch,
    AppAction.nextChannel,
    AppAction.previousChannel,
    AppAction.openSettings,
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    // Keycaps only where a keyboard is; a finger cannot press any of these.
    final keyboard = !AppTouchTargets.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tokens.surfaceRaised,
                shape: BoxShape.circle,
              ),
              child: Icon(AppIcons.hash, size: 26, color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            Text(
              'Pick a channel to start reading.',
              style: AppText.title.copyWith(color: tokens.textPrimary),
            ),
            if (!keyboard) ...[
              const SizedBox(height: AppSpacing.s4),
              Text(
                'Choose one from the list.',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: tokens.textSecondary),
              ),
            ] else ...[
              const SizedBox(height: AppSpacing.s20),
              for (final action in _shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.s8),
                  child: _ShortcutHint(action: action, tokens: tokens),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One row of the empty pane's shortcut list: what it does, and the keys.
///
/// Two equal halves meeting on the pane's centre line, so the seam between
/// labels and keycaps lines up under the icon and heading above it.
class _ShortcutHint extends StatelessWidget {
  const _ShortcutHint({required this.action, required this.tokens});

  final AppAction action;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final keys = describeAppAction(action);
    if (keys.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Row(
        children: [
          Expanded(
            child: Text(
              action.label,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: AppText.body.copyWith(color: tokens.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            // Keycaps shrink rather than cut in a narrow pane.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, key) in keys.indexed) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          '+',
                          style: AppText.micro.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    AppKbd(key),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
