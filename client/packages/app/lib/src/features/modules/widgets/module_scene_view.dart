// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The interactive surface for a module scene: it paints the current scene,
/// turns taps and control presses into actions, hands them back to the module,
/// and swaps in whatever scene comes back - so an animated or playable module
/// runs as a loop of ordinary stateless calls.
///
/// A module is a pure function of `(command, input)`; there is no session and
/// nothing persists between calls. This widget supplies the continuity: the
/// board rides in the scene's opaque [ModuleScene.state], and every step, tap
/// or reset is a fresh call carrying that state back. `play` is the only
/// client-side control - a timer that keeps asking the module to `step` until
/// the scene reports it can no longer change ([ModuleScene.live]) or the
/// viewer pauses. It takes [runCommand] rather than reaching for the API
/// itself, so it is decoupled from how a scene gets run (a code block, the
/// Dock panel) and can be driven directly in a test.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import 'module_scene.dart';
import 'module_scene_bounds.dart';
import 'module_scene_busy.dart';
import 'module_scene_images.dart';
import 'module_scene_inputs.dart';
import 'module_scene_footer.dart';
import 'module_scene_frame.dart';
import 'module_scene_keyboard.dart';
import 'module_scene_pacing.dart';
import 'module_scene_queue.dart';
import 'module_scene_painter.dart';
import 'module_scene_timeline.dart';
import '../../messages/widgets/swipe_to_reply.dart';

const _runActionTask = 'run a module action';

/// Runs one action against the module and returns its raw result. The action
/// and the current scene state are already packed into [input] as
/// `{"action":...,"state":...}`.
typedef ModuleSceneRunner =
    Future<api.RunModuleCommandResult> Function(String input);

class ModuleSceneView extends StatefulWidget {
  const ModuleSceneView({
    super.key,
    required this.initial,
    required this.runCommand,
    this.onNotes,
    this.fillAvailable = false,
    this.onExpand,
  });

  final ModuleScene initial;
  final ModuleSceneRunner runCommand;

  /// Called with a `notes` op's notes when - and only when - the scene that
  /// carried it just came back as the direct result of this viewer's own tap,
  /// drag or control press. Never called for the initial scene a message
  /// mounts with, and never for a scene update that arrived because another
  /// viewer acted on one shared with this one (see [_isOwnWork]): that is
  /// what keeps a module's sound from ever playing on someone else's say-so.
  /// Null means the caller has nothing to play through - the Dock command
  /// panel's own ephemeral runs, say - not that sound is disabled; the
  /// enabled/disabled decision belongs to the caller that supplies this.
  final void Function(List<SceneNote> notes)? onNotes;

  /// Whether this is the full-screen presentation: it takes all the room
  /// there is and offers no expand control, being already expanded.
  final bool fillAvailable;

  /// Opens this scene full screen. Absent means no expand control is offered -
  /// the Dock panel's ephemeral runs have nowhere to expand to, and the
  /// full-screen view itself is already there.
  final FutureOr<void> Function()? onExpand;

  @override
  State<ModuleSceneView> createState() => _ModuleSceneViewState();
}

class _ModuleSceneViewState extends State<ModuleSceneView>
    with WidgetsBindingObserver {
  /// How fast this may ask, and what to do when told it is asking too fast.
  /// Shared by play's timer and the drag queue; see [ScenePacing].
  final _pacing = ScenePacing();

  late ModuleScene _scene = widget.initial;
  Timer? _timer;

  /// Decoded bitmaps for this view's `image` ops; see `module_scene_images.dart`.
  final _images = SceneImageCache();
  bool _busy = false;
  bool _playing = false;
  String? _error;

  final _queue = SceneActionQueue();

  /// The last few scene states this view produced itself.
  ///
  /// A scene that belongs to a message is shared: every action stores the new
  /// output on the message and broadcasts it, so this widget's own step comes
  /// straight back as a new [widget.initial]. Without this it read as somebody
  /// starting a new run and stopped the very timer that had just produced it -
  /// press play, watch exactly one generation, then nothing.
  final _ownStates = <String>{};
  static const _ownStateMemory = 8;

  @override
  void initState() {
    super.initState();
    _rememberOwn(widget.initial.state);
    WidgetsBinding.instance.addObserver(this);
    // A finished decode changes what this paints with no scene or tap involved.
    _images.addListener(_onImageDecoded);
  }

  // Play asks the server every tick, so it must not run unseen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _playing) _stopAndRepaint();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled && _playing) _stop();
  }

  void _onImageDecoded() {
    if (mounted) setState(() {});
  }

  /// A genuinely new run - somebody re-Ran the block, or another viewer acted
  /// on a shared scene - resets this view and stops any animation. This
  /// widget's own work does not, even though on the shared path it arrives by
  /// exactly the same route: see [_ownStates].
  @override
  void didUpdateWidget(ModuleSceneView old) {
    super.didUpdateWidget(old);
    if (old.initial.state == widget.initial.state) return;
    if (_isOwnWork(widget.initial.state)) {
      _rememberOwn(widget.initial.state);
      if (_scene.state != widget.initial.state) {
        setState(() => _scene = keepCropStable(_scene, widget.initial));
      }
      return;
    }
    _stop();
    _queue.clear();
    _rememberOwn(widget.initial.state);
    setState(() => _scene = keepCropStable(_scene, widget.initial));
  }

  /// Whether a scene arriving from above is this view's own, rather than a
  /// new run to reset for. A call in flight or a queue still draining is the
  /// answer on its own: the broadcast can beat this view's own response back,
  /// so the state would not be in [_ownStates] yet even though it is ours.
  bool _isOwnWork(String? state) =>
      _busy ||
      _queue.isNotEmpty ||
      (state != null && _ownStates.contains(state));

  void _rememberOwn(String? state) {
    if (state == null) return;
    _ownStates.add(state);
    if (_ownStates.length > _ownStateMemory) {
      _ownStates.remove(_ownStates.first);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _images.removeListener(_onImageDecoded);
    _images.dispose();
    super.dispose();
  }

  /// [queued] marks an action the drag queue is draining, which is the only
  /// caller a refusal paces rather than reports: a control press is one
  /// deliberate act and has to say straight away that it did nothing.
  Future<void> _send(String action, {bool queued = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _runAction(action);
    } on api.RateLimitedException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, _runActionTask, e, stack);
      await _onRateLimited(e, action, queued: queued);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, _runActionTask, e, stack);
      _failWith(describeApiFailure('run this', e));
    } catch (error, stack) {
      api.reportFailure(api.LogTag.ui, _runActionTask, error, stack);
      _failWith('Could not run this.');
    } finally {
      // A drag queued behind play's own step has nothing else to restart it.
      if (mounted && !_busy && _queue.isNotEmpty) unawaited(_drain());
    }
  }

  Future<void> _runAction(String action) async {
    final result = await widget.runCommand(
      jsonEncode({'action': action, 'state': _scene.state ?? ''}),
    );
    if (!mounted) return;
    final next = result.ok && result.output != null
        ? parseModuleScene(result.output!)
        : null;
    if (next != null) {
      _rememberOwn(next.state);
      _pacing.succeeded();
    }
    setState(() {
      _busy = false;
      if (next != null) {
        _scene = keepCropStable(_scene, next);
        _playNotes(next);
        if (!next.live) _stop();
      } else {
        _stop();
        _error = result.error ?? 'The module returned nothing to draw.';
      }
    });
  }

  Future<void> _onRateLimited(
    api.RateLimitedException e,
    String action, {
    required bool queued,
  }) async {
    if (!mounted) return;
    _backOff(e.retryAfter);
    if (_playing && !_pacing.exhausted) {
      setState(() => _busy = false);
      return;
    }
    if (queued && !_pacing.exhausted) {
      // Put it back and hold: see _drain on why not just drop it.
      _queue.putBack(action);
      await Future<void>.delayed(_pacing.interval);
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }
    _queue.clear();
    _failWith(describeApiFailure('run this', e));
  }

  void _failWith(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stop();
      _error = message;
    });
  }

  /// The one call site that may ever trigger [widget.onNotes]: right where
  /// this view's own action just came back with a fresh scene, which is the
  /// only moment that satisfies "the viewer interacted with this scene" - see
  /// [widget.onNotes]'s own doc comment.
  void _playNotes(ModuleScene scene) {
    final notes = scene.ops
        .whereType<NotesOp>()
        .expand((op) => op.notes)
        .toList(growable: false);
    if (notes.isNotEmpty) widget.onNotes?.call(notes);
  }

  void _togglePlay() {
    if (_playing) {
      _stopAndRepaint();
      return;
    }
    // A fresh press starts at full speed again; see ScenePacing.reset.
    _pacing.reset();
    setState(() => _playing = true);
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_pacing.interval, (_) {
      if (!_busy && _scene.live) {
        _send('step');
      } else if (!_scene.live) {
        _stopAndRepaint();
      }
    });
  }

  /// Slows down after a refusal, and re-arms play's timer at the new interval.
  void _backOff(Duration? retryAfter) {
    _pacing.backOff(retryAfter);
    if (_playing) _startTimer();
  }

  /// Cancels the timer and clears the flag, with no rebuild of its own: two of
  /// the three callers are already inside a `setState`, and nesting one is an
  /// error. [_stopAndRepaint] is the version for the callers that are not.
  void _stop() {
    _timer?.cancel();
    _timer = null;
    _playing = false;
  }

  /// Stops, and repaints the control that says so. Pressing pause used to
  /// call [_stop] directly, which left `_playing` false while the button
  /// still drew a pause glyph and its active highlight. The animation really
  /// had stopped, so the only feedback was the board going still, and
  /// pressing the button again started it while the icon still said pause -
  /// a control whose state was the opposite of what it showed.
  void _stopAndRepaint() {
    if (!mounted) {
      _stop();
      return;
    }
    setState(_stop);
  }

  /// Where the current gesture began, remembered because `onPanStart` reports
  /// the point at which the drag was *recognised* rather than the point the
  /// finger came down on. Those are a cell or two apart, so a line drawn by
  /// dragging was missing the cell it started in until this was recorded here.
  Offset? _downAt;

  /// The raw pointer-down, not `onTapDown`: the tap recogniser is rejected
  /// before its own deadline when a drag is quick, so `onTapDown` never fires
  /// for exactly the gestures this needs to know the origin of.
  void _handlePointerDown(PointerDownEvent event) {
    _downAt = event.localPosition;
    _queue.startDrag();
  }

  void _handleTapUp(TapUpDetails details, Size size) {
    final action = sceneTapAction(_scene, details.localPosition, size);
    if (action != null) _enqueue(action);
  }

  void _handleSecondary(Offset at, Size size) {
    final action = sceneTapAction(_scene, at, size, secondary: true);
    if (action != null) _enqueue(action);
  }

  /// Paints the cell the finger actually landed on, then the one the drag was
  /// recognised in. The dedupe set makes the common case, where they are the
  /// same cell, a single paint.
  void _handlePanStart(DragStartDetails details, Size size) {
    final down = _downAt;
    if (down != null) _paintCell(down, size);
    _paintCell(details.localPosition, size);
  }

  void _handlePanUpdate(DragUpdateDetails details, Size size) =>
      _paintCell(details.localPosition, size);

  /// Sends the cell under [local] once per drag. Ops that answer a bare action
  /// rather than a cell (a button drawn into the scene) are ignored here: a
  /// drag across one is not a press of it.
  void _paintCell(Offset local, Size size) {
    final action = sceneTapAction(_scene, local, size);
    if (action == null || !action.contains(':')) return;
    if (!_queue.markPainted(action)) return;
    _enqueue(action);
  }

  void _enqueue(String action) {
    _queue.add(action);
    unawaited(_drain());
  }

  /// Sends queued actions, coalescing what the module said it can read in one
  /// go. Re-entrant calls return immediately, so the drain already running is
  /// the only one.
  ///
  /// A refusal pauses this rather than ending it. [_send] puts the refused
  /// action back at the front and waits [ScenePacing.interval] before letting
  /// the loop continue, so a burst limit paces the rest of a drawn line instead
  /// of emptying the queue against a closed limit - dropping it would leave the
  /// line unfinished, which is the same hole the queue exists to avoid. After
  /// [ScenePacing.maxRefusals] waits in a row it does give up, once, with one
  /// error.
  Future<void> _drain() async {
    while (_queue.isNotEmpty && mounted) {
      // Per iteration: play's step can take _busy between sends.
      if (_busy) return;
      await _send(_queue.takeNext(_scene), queued: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fillAvailable) return _content(context);
    final windowHeight = MediaQuery.sizeOf(context).height;
    final aspect = _scene.viewHeight == 0
        ? 1.0
        : _scene.viewWidth / _scene.viewHeight;
    // The caption and controls take the frame's width, never widen the card past it.
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: ModuleSceneFrame.inlineWidth(
          maxWidth: constraints.hasBoundedWidth ? constraints.maxWidth : null,
          windowHeight: windowHeight,
          aspect: aspect,
          sceneHeight: _scene.viewHeight,
        ),
        child: _content(
          context,
          cardWidth: constraints.hasBoundedWidth ? constraints.maxWidth : null,
        ),
      ),
    );
  }

  Widget _content(BuildContext context, {double? cardWidth}) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final aspect = _scene.viewHeight == 0
        ? 1.0
        : _scene.viewWidth / _scene.viewHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.fillAvailable)
          Expanded(child: _frame(aspect, tokens, cardWidth))
        else
          _frame(aspect, tokens, cardWidth),
        ModuleSceneFooter(
          scene: _scene,
          tokens: tokens,
          error: _error,
          onDismissError: () => setState(() => _error = null),
          playing: _playing,
          onTogglePlay: _togglePlay,
          onAction: _send,
          onExpand: widget.onExpand,
        ),
      ],
    );
  }

  /// The board itself, in its box. Split out because full screen wraps it in
  /// an [Expanded] and inline does not, and a widget cannot be both.
  Widget _frame(
    double aspect,
    AppTokens tokens,
    double? cardWidth,
  ) => ModuleSceneFrame(
    aspect: aspect,
    cardWidth: cardWidth,
    sceneHeight: _scene.viewHeight,
    fillAvailable: widget.fillAvailable,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return SceneKeyboardGrid(
          scene: _scene,
          size: size,
          onActivate: _enqueue,
          child: SwipeToReplyOptOut(
            child: Listener(
              onPointerDown: _handlePointerDown,
              child: GestureDetector(
                onTapUp: (d) => _handleTapUp(d, size),
                onSecondaryTapUp: _scene.hasSecondary
                    ? (d) => _handleSecondary(d.localPosition, size)
                    : null,
                // Only a scene that answers one: a held tap otherwise still reads as a tap.
                onLongPressStart: _scene.hasSecondary
                    ? (d) => _handleSecondary(d.localPosition, size)
                    : null,
                onPanStart: (d) => _handlePanStart(d, size),
                onPanUpdate: (d) => _handlePanUpdate(d, size),
                child: Stack(
                  children: [
                    SceneTimeline(
                      scene: _scene,
                      tokens: tokens,
                      images: _images.snapshot(_scene),
                      size: size,
                    ),
                    // Above the paint: a tap for a field must not also fall through.
                    SceneInputOverlay(
                      scene: _scene,
                      size: size,
                      onSubmit: _enqueue,
                    ),
                    Positioned(
                      top: AppSpacing.s8,
                      right: AppSpacing.s8,
                      child: SceneBusyIndicator(busy: _busy, tokens: tokens),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
