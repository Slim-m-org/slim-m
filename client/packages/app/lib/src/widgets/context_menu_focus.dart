// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The keyboard route into a context menu, used by `MessageContextMenuRegion`.
///
/// The menu opens on a right-click or a long press only, which left edit,
/// delete, pin, report and block with no keyboard route at all: the row took
/// no focus and no key opened the menu. A screen reader was always fine,
/// because `GestureDetector` publishes `SemanticsAction.longPress` for its own
/// `onLongPress`, and `context_menu_reachability_test` guards that.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

/// Asks the enclosing region to open its context menu.
class OpenContextMenuIntent extends Intent {
  const OpenContextMenuIntent();
}

/// The platform's own pair, rather than a binding invented here: the
/// dedicated context-menu key beside right Control, and Shift+F10, which is
/// what a keyboard without that key uses everywhere else.
///
/// Enter and Space are deliberately left alone. They are a row's primary
/// activation, and a message row hands them to the controls it contains.
const Map<ShortcutActivator, Intent> _openShortcuts = {
  SingleActivator(LogicalKeyboardKey.contextMenu): OpenContextMenuIntent(),
  SingleActivator(LogicalKeyboardKey.f10, shift: true): OpenContextMenuIntent(),
};

/// Makes [child] a tab stop whose context menu opens from the keyboard.
///
/// Focus draws an outline ring in [AppTokens.focusRing], the cue [AppListRow]
/// and [AppMenuItem] already draw through the same [FocusableActionDetector].
/// Shape has to carry it: `focusRing` and `accentFill` hold the same value in
/// every theme, so a fill here would read as selection instead.
///
/// The ring's box is mounted whether or not it is drawn, because inserting a
/// widget above [child] on focus would re-inflate the row and drop the state
/// of everything under it.
///
/// [ownsFocusNode] is false for a [child] that is already its own tab stop
/// (an [AppListRow], say): a second [FocusableActionDetector] around one of
/// those would add a second, redundant stop that Tab has to pass through
/// before Enter reaches the row's own activation again, and the context-menu
/// key still has to reach that same, single node either way. `false` instead
/// binds the shortcut through a plain [Shortcuts]/[Actions] pair, which asks
/// nothing of the focus tree at all and rides whatever [child] already made
/// focusable.
class ContextMenuFocus extends StatefulWidget {
  const ContextMenuFocus({
    super.key,
    required this.onOpen,
    required this.child,
    this.focusNode,
    this.ownsFocusNode = true,
  });

  final VoidCallback onOpen;

  /// Supplied by a caller that drives focus itself; one is created here when
  /// it is null. Meaningless when [ownsFocusNode] is false.
  final FocusNode? focusNode;

  final bool ownsFocusNode;

  final Widget child;

  @override
  State<ContextMenuFocus> createState() => _ContextMenuFocusState();
}

class _ContextMenuFocusState extends State<ContextMenuFocus> {
  bool _focused = false;

  Map<Type, Action<Intent>> get _actions => <Type, Action<Intent>>{
    OpenContextMenuIntent: CallbackAction<OpenContextMenuIntent>(
      onInvoke: (_) {
        widget.onOpen();
        return null;
      },
    ),
  };

  @override
  Widget build(BuildContext context) {
    if (!widget.ownsFocusNode) {
      return Shortcuts(
        shortcuts: _openShortcuts,
        child: Actions(actions: _actions, child: widget.child),
      );
    }

    final tokens = Theme.of(context).extension<AppTokens>()!;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      shortcuts: _openShortcuts,
      actions: _actions,
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: _focused
            ? BoxDecoration(
                border: Border.all(color: tokens.focusRing, width: 2),
                borderRadius: BorderRadius.circular(AppRadii.control),
              )
            : const BoxDecoration(),
        child: widget.child,
      ),
    );
  }
}

/// The other half of that route: an open menu takes focus, so its items can be
/// reached with Tab and run with Enter, and Escape closes it.
///
/// Focus is moved in explicitly rather than left to `autofocus`, which only
/// fires when nothing else holds focus and so never fires here: the row that
/// opened the menu is exactly what does.
///
/// [Actions] sits above the scope, so Escape is answered from the moment the
/// menu opens. An intent is dispatched upward from whatever holds focus, and
/// the scope node itself would otherwise sit above the only widget able to
/// answer it.
///
/// Focus returns to the row on close with nothing here doing it: dismantling a
/// scope hands focus back to the parent scope's last focused child.
class ContextMenuKeyboardScope extends StatefulWidget {
  const ContextMenuKeyboardScope({
    super.key,
    required this.onDismiss,
    required this.child,
  });

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<ContextMenuKeyboardScope> createState() =>
      _ContextMenuKeyboardScopeState();
}

class _ContextMenuKeyboardScopeState extends State<ContextMenuKeyboardScope> {
  final _node = FocusScopeNode(debugLabel: 'context menu');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _node.requestFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            widget.onDismiss();
            return null;
          },
        ),
      },
      // Bound here, not left to the app default: an OverlayPortal menu sits under its opener's own Escape bindings.
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: FocusScope(
          node: _node,
          child: FocusTraversalGroup(child: widget.child),
        ),
      ),
    );
  }
}
