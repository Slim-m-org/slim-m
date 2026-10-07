// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal space row's own kebab.
///
/// Split out of `personal_space_row.dart` for the same reason
/// `space_menu_button.dart` sits apart from `channel_rail_frame.dart`: the
/// row's own tap-to-open logic is a different concern from an overlay
/// menu's wiring. Its reveal-on-hover, always-on-touch treatment mirrors
/// `channel_rail_channel_rows.dart`'s `ManagedChannelRow` kebab; unlike
/// that one, there is no manage sheet behind it, only "Remove from list",
/// since a personal space cannot be renamed or deleted, only hidden.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/personal_space_visibility.dart';
import '../providers/toasts.dart';
import 'anchored_menu.dart';
import 'animated_menu_portal.dart';

/// The message shown when the row is hidden, naming the one way back:
/// searching the caller's own display name surfaces it again in the command
/// palette (`command_palette_items.dart`'s `channelMatchesQuery`), and
/// selecting that result un-hides it.
const String personalSpaceHiddenNotice =
    'Removed from your list. Search your own name to find it again.';

/// Shown for [visible] (touch, hover, or keyboard focus reaching it), the
/// same rule the ordinary channel kebab follows.
class PersonalSpaceKebab extends ConsumerStatefulWidget {
  const PersonalSpaceKebab({
    super.key,
    required this.visible,
    required this.onFocusChange,
  });

  final bool visible;
  final ValueChanged<bool> onFocusChange;

  @override
  ConsumerState<PersonalSpaceKebab> createState() => _PersonalSpaceKebabState();
}

class _PersonalSpaceKebabState extends ConsumerState<PersonalSpaceKebab> {
  final _controller = AnimatedMenuController();

  Future<void> _remove() async {
    _controller.hide();
    final container = ProviderScope.containerOf(context, listen: false);
    await ref.read(personalSpaceVisibilityProvider.notifier).hide();
    container
        .read(toastsProvider.notifier)
        .show(personalSpaceHiddenNotice, severity: AppToastSeverity.success);
  }

  @override
  Widget build(BuildContext context) {
    return AnchoredMenu(
      controller: _controller,
      menu: AppMenu(
        width: 220,
        children: [
          AppMenuItem(
            label: 'Remove from list',
            leading: AppIcons.removeFromList,
            onTap: () => unawaited(_remove()),
          ),
        ],
      ),
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onFocusChange: widget.onFocusChange,
        child: AnimatedOpacity(
          opacity: widget.visible ? 1 : 0,
          duration: AppMotion.reduced(context, AppMotion.fast),
          // Hidden from the eye is not hidden from a screen reader.
          alwaysIncludeSemantics: true,
          child: AppIconButton(
            icon: AppIcons.moreVertical,
            semanticLabel: 'Personal space options',
            size: AppIconButtonSize.sm,
            onPressed: _controller.toggle,
            // The row's own tint already covers this kebab; see the param's own doc.
            suppressOwnHoverFill: true,
          ),
        ),
      ),
    );
  }
}
