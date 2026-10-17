// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drag a message row left to right to reply to it, on phone-width layouts.
///
/// Built on one custom recogniser rather than a [GestureDetector] because a
/// plain horizontal drag claims the arena at touch slop, ahead of a child's pan
/// (slop 36), which is how the first version took a module board's strokes as
/// replies. The recogniser here only accepts a rightward, clearly horizontal
/// drag, and a child that takes horizontal drags says so with
/// [SwipeToReplyOptOut].
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Travel past which releasing commits the reply.
const double swipeToReplyThreshold = 56;

const double _maxTravel = 88;

/// A drag must run at least this many times further across than down.
const double _horizontalBias = 2;

class SwipeToReply extends StatefulWidget {
  const SwipeToReply({
    super.key,
    required this.enabled,
    required this.onReply,
    required this.child,
  });

  /// False on wide layouts and for any row Reply is hidden on.
  final bool enabled;

  final VoidCallback onReply;
  final Widget child;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _travel = AnimationController(
    vsync: this,
    upperBound: _maxTravel,
  );
  int? _optedOutPointer;
  bool _armed = false;

  void _optOut(int pointer) => _optedOutPointer = pointer;

  bool _allows(PointerEvent event) {
    final blocked = _optedOutPointer == event.pointer;
    _optedOutPointer = null;
    return widget.enabled && !blocked;
  }

  void _onUpdate(DragUpdateDetails details) {
    _travel.value = (_travel.value + details.delta.dx).clamp(0.0, _maxTravel);
    final armed = _travel.value >= swipeToReplyThreshold;
    if (armed != _armed) {
      _armed = armed;
      if (armed) AppHaptics.selection();
    }
  }

  void _onEnd(DragEndDetails details) {
    final commit = _armed;
    _snapBack();
    if (commit) {
      AppHaptics.success();
      widget.onReply();
    }
  }

  void _snapBack() {
    _armed = false;
    _travel.animateTo(
      0,
      duration: AppMotion.reduced(context, AppMotion.fast),
      curve: AppMotion.exit,
    );
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return _SwipeScope(
      optOut: _optOut,
      child: RawGestureDetector(
        gestures: {
          _ReplySwipeRecognizer:
              GestureRecognizerFactoryWithHandlers<_ReplySwipeRecognizer>(
                () => _ReplySwipeRecognizer(),
                (recognizer) => recognizer
                  ..allows = _allows
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd
                  ..onCancel = _snapBack,
              ),
        },
        child: AnimatedBuilder(
          animation: _travel,
          builder: (context, child) {
            final dx = _travel.value;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (dx > 0)
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.s16),
                        child: ExcludeSemantics(
                          child: Opacity(
                            opacity: (dx / swipeToReplyThreshold).clamp(
                              0.0,
                              1.0,
                            ),
                            child: Icon(
                              AppIcons.reply,
                              size: 20,
                              color: _armed
                                  ? tokens.accent
                                  : tokens.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Transform.translate(offset: Offset(dx, 0), child: child),
              ],
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Accepts only a rightward drag that is clearly more across than down; the sign of the ratio check is what rules out leftward.
class _ReplySwipeRecognizer extends HorizontalDragGestureRecognizer {
  _ReplySwipeRecognizer() : super(supportedDevices: {PointerDeviceKind.touch});

  bool Function(PointerEvent event) allows = (_) => true;
  Offset _origin = Offset.zero;
  Offset _moved = Offset.zero;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      allows(event) && super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origin = event.position;
    _moved = Offset.zero;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) _moved = event.position - _origin;
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) =>
      _moved.dy.abs() * _horizontalBias <= _moved.dx &&
      super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind,
        deviceTouchSlop,
      );
}

class _SwipeScope extends InheritedWidget {
  const _SwipeScope({required this.optOut, required super.child});

  final void Function(int pointer) optOut;

  @override
  bool updateShouldNotify(_SwipeScope old) => false;
}

/// Marks [child] as taking its own horizontal drags: a press that lands on it never starts a reply swipe.
class SwipeToReplyOptOut extends StatelessWidget {
  const SwipeToReplyOptOut({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_SwipeScope>();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => scope?.optOut(event.pointer),
      child: child,
    );
  }
}
