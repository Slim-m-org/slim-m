// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The row of buttons under a module scene.
///
/// Split out of `module_scene_view.dart` when the full-screen presentation
/// pushed that file past the review ceiling. They are free functions taking
/// what they need rather than methods on the view's state, which also makes
/// the set of things a control may touch explicit: the control names, whether
/// play is running, and two callbacks. A control cannot reach anything else.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

List<Widget> sceneControls({
  required List<String> controls,
  required bool playing,
  required VoidCallback onTogglePlay,
  required void Function(String action) onAction,
}) {
  final widgets = <Widget>[];
  for (final control in controls) {
    widgets.add(_controlButton(control, playing, onTogglePlay, onAction));
  }
  return widgets;
}

/// One control's button.
///
/// A reserved name gets its icon. Anything else is what the module called it,
/// rendered as a labelled button that sends that name back as the action - so
/// a module can offer a verb this client has never heard of, which is the
/// whole point of the contract. Returning null here is what used to happen
/// instead, and it meant a module could declare a control, see no button, and
/// have nothing say why.
///
/// Deliberately never disabled on [_busy]. It used to be, and while playing
/// that meant every control greyed out and came back on each generation -
/// a visible flicker at eight times a second, reported as the buttons
/// flashing. A press landing mid-call is already a no-op, because [_send]
/// refuses a second call while one is in flight, so disabling them bought
/// nothing the guard did not already do and cost that.
Widget _controlButton(
  String control,
  bool playing,
  VoidCallback onTogglePlay,
  void Function(String action) onAction,
) {
  switch (control) {
    case 'play':
      return AppIconButton(
        icon: playing ? AppIcons.pause : AppIcons.play,
        semanticLabel: playing ? 'Pause' : 'Play',
        tooltip: playing ? 'Pause' : 'Play',
        active: playing,
        onPressed: onTogglePlay,
      );
    case 'step':
      return AppIconButton(
        icon: AppIcons.forward,
        semanticLabel: 'Step forward',
        tooltip: 'Step forward',
        onPressed: () => onAction('step'),
      );
    case 'random':
      return AppIconButton(
        icon: AppIcons.highlight,
        semanticLabel: 'Randomise',
        tooltip: 'Randomise',
        onPressed: () => onAction('random'),
      );
    case 'clear':
      return AppIconButton(
        icon: AppIcons.eraser,
        semanticLabel: 'Clear',
        tooltip: 'Clear',
        onPressed: () => onAction('clear'),
      );
    case 'reset':
      return AppIconButton(
        icon: AppIcons.retry,
        semanticLabel: 'Reset',
        tooltip: 'Reset',
        onPressed: () => onAction('reset'),
      );
    default:
      return _CustomControl(label: control, onPressed: () => onAction(control));
  }
}

/// A control this client has no icon for, drawn as its own name.
///
/// Lowercase as the module wrote it: these read as verbs in a sentence under
/// the scene ("play tune", "tempo"), and title-casing somebody else's label
/// would be this client deciding how their module speaks.
class _CustomControl extends StatelessWidget {
  const _CustomControl({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => AppButton(
    label: label,
    size: AppButtonSize.sm,
    variant: AppButtonVariant.secondary,
    onPressed: onPressed,
    semanticLabel: label,
  );
}
