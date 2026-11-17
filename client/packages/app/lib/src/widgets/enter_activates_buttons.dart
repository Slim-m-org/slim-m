// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enter presses the focused control on the web build too.
///
/// Flutter's web shortcuts send Enter as a [ButtonActivateIntent], which only
/// Material's own buttons answer, while every control here answers
/// [ActivateIntent]. This turns the first into the second for whatever holds
/// focus, except a text field, whose Enter is its own (submit, or send).
library;

import 'package:flutter/widgets.dart';

class EnterActivatesButtons extends StatelessWidget {
  const EnterActivatesButtons({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: <Type, Action<Intent>>{ButtonActivateIntent: _ActivateFocused()},
    child: child,
  );
}

class _ActivateFocused extends Action<ButtonActivateIntent> {
  BuildContext? get _target {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return null;
    if (context.findAncestorStateOfType<EditableTextState>() != null) {
      return null;
    }
    final action = Actions.maybeFind<ActivateIntent>(context);
    if (action == null || !action.isEnabled(const ActivateIntent())) {
      return null;
    }
    return context;
  }

  @override
  bool isEnabled(ButtonActivateIntent intent) => _target != null;

  @override
  Object? invoke(ButtonActivateIntent intent) {
    final target = _target;
    if (target == null) return null;
    return Actions.invoke(target, const ActivateIntent());
  }
}
