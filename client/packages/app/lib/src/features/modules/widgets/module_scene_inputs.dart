// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real text fields an [InputOp] asks for, laid over a painted scene.
///
/// A painter cannot draw a text field - it has a cursor, a keyboard, focus and
/// a selection - so `input` is the one scene op that is a widget rather than
/// paint. This overlays those widgets on the canvas at the scene coordinates
/// the module gave, and reports a submission back as an action.
///
/// Its own file because it is the only stateful part of rendering a scene:
/// everything else in `module_scene_view.dart` is derived from the current
/// scene, and a field in the middle of being typed into is not.
///
/// The module owns the value. Whatever comes back in the next scene is what the
/// field shows, so a module can correct, clear or reformat a submission. The one
/// exception is a field somebody is typing in right now: overwriting that under
/// their cursor would make the app feel like it was fighting them, so a scene
/// arriving while a field has focus leaves that field alone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene.dart';

class SceneInputOverlay extends StatefulWidget {
  const SceneInputOverlay({
    super.key,
    required this.scene,
    required this.size,
    required this.onSubmit,
  });

  final ModuleScene scene;

  /// The painted box, so scene units can be scaled the way the painter scales
  /// them.
  final Size size;

  /// Called with `"<submit>:<text>"`, the same colon-separated action shape a
  /// tapped cell reports.
  final ValueChanged<String> onSubmit;

  @override
  State<SceneInputOverlay> createState() => _SceneInputOverlayState();
}

class _SceneInputOverlayState extends State<SceneInputOverlay> {
  /// One controller and focus node per submit name, kept across scenes so
  /// typing survives a frame arriving from somebody else's action.
  final _controllers = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};

  /// What the module last said the value was, so a scene that did not change it
  /// does not get to reset the field.
  final _lastFromModule = <String, String>{};

  @override
  void initState() {
    super.initState();
    _sync();
  }

  /// Fields whose entry was just sent and whose next scene has not arrived.
  final _awaitingReply = <String>{};

  @override
  void didUpdateWidget(SceneInputOverlay old) {
    super.didUpdateWidget(old);
    _sync(newScene: !identical(old.scene, widget.scene));
  }

  /// Sends the entry, empties the field and keeps the caret in it, so the next
  /// entry can be typed at once. The module's reply still decides the value.
  void _submit(InputOp op, String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      widget.onSubmit('${op.submit}:$trimmed');
      _controllers[op.submit]?.clear();
      _awaitingReply.add(op.submit);
    }
    // Done unfocuses a field after onSubmitted runs, so ask once that has happened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus[op.submit]?.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Brings the controllers in line with the current scene: a field per input
  /// op, seeded from the module's value, and nothing left over for an op that
  /// has gone.
  void _sync({bool newScene = false}) {
    final ops = _inputs();
    final names = ops.map((op) => op.submit).toSet();

    for (final name in _controllers.keys.toList()) {
      if (names.contains(name)) continue;
      _controllers.remove(name)?.dispose();
      _focus.remove(name)?.dispose();
      _lastFromModule.remove(name);
      _awaitingReply.remove(name);
    }

    for (final op in ops) {
      final controller = _controllers.putIfAbsent(
        op.submit,
        () => TextEditingController(text: op.value),
      );
      _focus.putIfAbsent(op.submit, FocusNode.new);

      final changedByModule = _lastFromModule[op.submit] != op.value;
      _lastFromModule[op.submit] = op.value;
      // Only a scene that changes this field is the reply; a stray one must not use it up.
      final answered =
          newScene && changedByModule && _awaitingReply.remove(op.submit);
      final hasFocus = _focus[op.submit]?.hasFocus ?? false;
      // An answered field is empty unless a next entry was typed before the reply.
      final beingTyped = hasFocus && (!answered || controller.text.isNotEmpty);
      if ((changedByModule || answered) &&
          !beingTyped &&
          controller.text != op.value) {
        controller.text = op.value;
      }
    }
  }

  List<InputOp> _inputs() => widget.scene.ops.whereType<InputOp>().toList();

  @override
  Widget build(BuildContext context) {
    final ops = _inputs();
    if (ops.isEmpty) return const SizedBox.shrink();

    final scene = widget.scene;
    final sx = scene.viewWidth == 0 ? 1.0 : widget.size.width / scene.viewWidth;
    final sy = scene.viewHeight == 0
        ? 1.0
        : widget.size.height / scene.viewHeight;

    return Stack(
      children: [
        for (final op in ops)
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _FieldLayout(
                left: (op.x - scene.viewLeft) * sx,
                top: (op.y - scene.viewTop) * sy,
                width: op.w * sx,
              ),
              child: AppInput(
                controller: _controllers[op.submit],
                focusNode: _focus[op.submit],
                placeholder: op.placeholder,
                size: AppInputSize.sm,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(op.maxLength),
                ],
                semanticLabel: op.placeholder ?? 'Scene input',
                textInputAction: TextInputAction.done,
                onSubmitted: (text) => _submit(op, text),
              ),
            ),
          ),
      ],
    );
  }
}

/// Places a field at its scene position but never lower than it fits, since a
/// field has a pixel height the scene's units cannot promise room for.
class _FieldLayout extends SingleChildLayoutDelegate {
  const _FieldLayout({
    required this.left,
    required this.top,
    required this.width,
  });

  final double left;
  final double top;
  final double width;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: width);

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    left.clamp(0.0, (size.width - childSize.width).clamp(0.0, double.infinity)),
    top.clamp(
      0.0,
      (size.height - childSize.height).clamp(0.0, double.infinity),
    ),
  );

  @override
  bool shouldRelayout(_FieldLayout old) =>
      left != old.left || top != old.top || width != old.width;
}
