// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A message row that can be picked while the transcript is in selection
/// mode, and is untouched when it is not.
///
/// A wrapper rather than parameters on `MessageRow`. That widget already
/// carries fifteen-odd callbacks and is 389 lines; selection concerns whether
/// a row is *chosen*, not how it draws, and threading two more flags through
/// it would put mode-handling inside every part of the row that has nothing
/// to do with the mode.
///
/// While the mode is off this adds no gesture handler at all, so a normal
/// transcript keeps every interaction it has - hover actions, links, text
/// selection, the context menu. While it is on, the whole row becomes one
/// target and the row's own interactions are deliberately suppressed:
/// half-live rows, where a tap selects but a link still navigates away, are
/// the usual way this pattern goes wrong.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/message_selection.dart';

class MessageSelectable extends ConsumerWidget {
  const MessageSelectable({
    required this.channelId,
    required this.messageId,
    required this.child,
    this.order = const [],
    super.key,
  });

  final String channelId;
  final String messageId;
  final Widget child;

  /// The transcript's message ids, oldest first, for a shift-tap to extend
  /// the selection along (see [MessageSelectionController.extendTo]). Shift
  /// is a keyboard concept, so touch keeps its tap-per-message flow untouched.
  final List<String> order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(messageSelectionProvider(channelId));
    if (!selection.active) return child;

    final tokens = Theme.of(context).extension<AppTokens>()!;
    final selected = selection.contains(messageId);
    // Full, but not this row, so tapping it could only ever add: no affordance.
    final refuses = selection.atCap && !selected;

    return Semantics(
      selected: selected,
      button: true,
      label: selected ? 'Selected, tap to deselect' : 'Tap to select',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: refuses ? null : () => _pick(ref),
        child: ColoredBox(
          color: selected ? tokens.accentSoft : Colors.transparent,
          child: Opacity(
            opacity: refuses ? 0.4 : 1,
            // Absorbs the row's own taps, so a link cannot fire mid-selection.
            child: IgnorePointer(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.s8),
                    child: _Tick(selected: selected),
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _pick(WidgetRef ref) {
    final controller = ref.read(messageSelectionProvider(channelId).notifier);
    if (HardwareKeyboard.instance.isShiftPressed) {
      controller.extendTo(messageId, order);
    } else {
      controller.toggle(messageId);
    }
  }
}

/// The picked/not-picked mark. A ring rather than a Material checkbox, which
/// brings its own colours and 48px tap padding into a 36px-dense transcript.
class _Tick extends StatelessWidget {
  const _Tick({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: AppSizes.icon16,
      height: AppSizes.icon16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? tokens.accentFill : Colors.transparent,
        border: Border.all(
          color: selected ? tokens.accentFill : tokens.borderStrong,
        ),
      ),
      child: selected
          ? Icon(AppIcons.check, size: 11, color: tokens.accentOn)
          : null,
    );
  }
}
