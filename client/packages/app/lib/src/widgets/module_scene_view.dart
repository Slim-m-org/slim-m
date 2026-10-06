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

import '../api_failure.dart';
import 'module_scene.dart';
import 'module_scene_busy.dart';
import 'module_scene_images.dart';
import 'module_scene_inputs.dart';
import 'module_scene_controls.dart';
import 'module_scene_expand.dart';
import 'module_scene_frame.dart';
import 'module_scene_keyboard.dart';
import 'module_scene_pacing.dart';
import 'module_scene_painter.dart';
import 'module_scene_timeline.dart';

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

class _ModuleSceneViewState extends State<ModuleSceneView> {
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

  /// Actions waiting on the one in flight, oldest first.
  ///
  /// A module call is a round trip and only one runs at a time, so a drag
  /// across a grid produces actions faster than they can be sent. Dropping the
  /// ones that arrive while busy - which is what the [_busy] guard in [_send]
  /// does on its own - would leave holes in a drawn line, so they queue here
  /// and drain in order instead.
  final _queue = <String>[];

  /// Capped so a long drag on a fine grid cannot build a backlog the board
  /// spends a minute catching up on. A dropped tail is better than a board
  /// that keeps moving after the finger stops.
  static const _maxQueue = 64;

  /// Cells already sent during the current drag, so crossing one twice does
  /// not toggle it back off. Cleared when the drag starts.
  final _paintedThisDrag = <String>{};

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
    // A finished decode changes what this paints with no scene or tap involved.
    _images.addListener(_onImageDecoded);
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
        setState(() => _scene = widget.initial);
      }
      return;
    }
    _stop();
    _queue.clear();
    _paintedThisDrag.clear();
    _rememberOwn(widget.initial.state);
    setState(() => _scene = widget.initial);
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
          _scene = next;
          _playNotes(next);
          if (!next.live) _stop();
        } else {
          _stop();
          _error = result.error ?? 'The module returned nothing to draw.';
        }
      });
    } on api.RateLimitedException catch (e) {
      if (!mounted) return;
      _backOff(e.retryAfter);
      if (_playing && !_pacing.exhausted) {
        setState(() => _busy = false);
        return;
      }
      if (queued && !_pacing.exhausted) {
        // Put it back and hold: see _drain on why not just drop it.
        _queue.insert(0, action);
        await Future<void>.delayed(_pacing.interval);
        if (!mounted) return;
        setState(() => _busy = false);
        return;
      }
      _queue.clear();
      setState(() {
        _busy = false;
        _stop();
        _error = describeApiFailure('run this', e);
      });
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stop();
        _error = describeApiFailure('run this', e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stop();
        _error = 'Could not run this.';
      });
    } finally {
      // A drag queued behind play's own step has nothing else to restart it.
      if (mounted && !_busy && _queue.isNotEmpty) unawaited(_drain());
    }
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
    _paintedThisDrag.clear();
  }

  void _handleTapUp(TapUpDetails details, Size size) {
    final action = sceneTapAction(_scene, details.localPosition, size);
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
    if (!_paintedThisDrag.add(action)) return;
    _enqueue(action);
  }

  void _enqueue(String action) {
    if (_queue.length >= _maxQueue) return;
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
      await _send(_takeNext(), queued: true);
    }
  }

  /// The next call to make: one queued action, or every leading action sharing
  /// a prefix the module reads as a list, joined into one.
  ///
  /// A whole drag becomes a single round trip that way. Without it the queue
  /// still drains in order and nothing is lost - it just costs a call per cell,
  /// which over a real network is what made drawing feel like work.
  String _takeNext() {
    final first = _queue.removeAt(0);
    final prefix = first.split(':').first;
    if (!first.contains(':') || !sceneAllowsTapBatch(_scene, first)) {
      return first;
    }
    final cells = <String>[first.substring(prefix.length + 1)];
    while (_queue.isNotEmpty && _queue.first.startsWith('$prefix:')) {
      cells.add(_queue.removeAt(0).substring(prefix.length + 1));
    }
    return '$prefix:${cells.join(';')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final aspect = _scene.height == 0 ? 1.0 : _scene.width / _scene.height;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.fillAvailable)
          Expanded(child: _frame(aspect, tokens))
        else
          _frame(aspect, tokens),
        if (_scene.status != null) ...[
          const SizedBox(height: AppSpacing.s8),
          Text(
            _scene.status!,
            style: AppText.caption.copyWith(
              fontFamily: AppFonts.mono,
              color: tokens.textSecondary,
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(
            message: _error!,
            onDismiss: () => setState(() => _error = null),
          ),
        ],
        if (_scene.controls.isNotEmpty || widget.onExpand != null) ...[
          const SizedBox(height: AppSpacing.s8),
          // Wraps because a Row overflowed on a phone and clipped what sat last: the full-screen button.
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            children: [
              ...sceneControls(
                controls: _scene.controls,
                playing: _playing,
                onTogglePlay: _togglePlay,
                onAction: _send,
              ),
              if (widget.onExpand case final expand?)
                SceneExpandButton(onExpand: expand),
            ],
          ),
        ],
      ],
    );
  }

  /// The board itself, in its box. Split out because full screen wraps it in
  /// an [Expanded] and inline does not, and a widget cannot be both.
  Widget _frame(double aspect, AppTokens tokens) => ModuleSceneFrame(
    aspect: aspect,
    sceneHeight: _scene.height,
    fillAvailable: widget.fillAvailable,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return SceneKeyboardGrid(
          scene: _scene,
          size: size,
          onActivate: _enqueue,
          child: Listener(
            onPointerDown: _handlePointerDown,
            child: GestureDetector(
              onTapUp: (d) => _handleTapUp(d, size),
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
        );
      },
    ),
  );
}
