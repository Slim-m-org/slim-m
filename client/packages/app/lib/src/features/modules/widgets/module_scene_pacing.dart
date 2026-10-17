// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How fast a scene may ask its module for the next frame, and what to do when
/// the server answers that it is asking too fast.
///
/// Split out of `module_scene_view.dart` because this was play's private
/// property and should never have been. The shared code-block route is rate
/// limited as an ordinary write (30 burst, 5 a second refilling), and two
/// things in that view outrun it: play's timer, which had this pacing, and a
/// drag across a grid, which did not. A drag queues an action per cell, so a
/// module that never declared `tap_batch` sends a call per cell; when the burst
/// ran out, the refusal emptied the rest of the queue against a closed limit as
/// fast as the round trips came back, leaving the drawn line unfinished and
/// overwriting the error several times in one frame-span.
///
/// So the interval, the backoff and the run of refusals live here, where both
/// callers reach them, and can be exercised without a widget.
library;

class ScenePacing {
  /// How often play asks for the next generation, at its fastest.
  ///
  /// Not the rate it settles at: playing at this tick outruns the write budget,
  /// and a long run used to sail through the burst and then fail outright with
  /// "too many requests", which is a rate limit doing its job and an animation
  /// handling it badly. [backOff] is what turns that into pacing.
  static const tick = Duration(milliseconds: 130);

  /// The ceiling [interval] backs off to. Beyond a couple of seconds a board is
  /// not really playing any more, and something is wrong that waiting longer
  /// will not fix.
  static const maxTick = Duration(seconds: 2);

  /// How many refusals in a row a draining queue will wait through before the
  /// rest of it is dropped.
  ///
  /// There has to be a number: [maxTick] bounds each wait but not how many, and
  /// a limit that stays shut would otherwise leave a drag retrying for as long
  /// as the view is mounted. Three waits reach [maxTick] from [tick], so by the
  /// time this gives up it has already waited out the longest pause it believes
  /// in.
  static const maxRefusals = 3;

  Duration _interval = tick;
  int _refusals = 0;

  /// The interval to run at, between [tick] and [maxTick].
  Duration get interval => _interval;

  /// Whether a draining queue should give up rather than wait again.
  bool get exhausted => _refusals >= maxRefusals;

  /// Slows down after the server refused a call for asking too fast.
  ///
  /// Doubles, or waits whatever `Retry-After` asked for if that is longer,
  /// capped at [maxTick]. It does not speed back up inside a run: creeping back
  /// toward [tick] would find the limit again, and a board that keeps
  /// stuttering into refusals is worse than one that settled slightly slow.
  void backOff(Duration? retryAfter) {
    _refusals++;
    final doubled = _interval * 2;
    var next = retryAfter != null && retryAfter > doubled
        ? retryAfter
        : doubled;
    if (next > maxTick) next = maxTick;
    _interval = next;
  }

  /// A call that came back ends the run of refusals, so a queue that hit the
  /// limit once and then got through has its full allowance again. The interval
  /// deliberately stays where it backed off to; see [backOff].
  void succeeded() => _refusals = 0;

  /// Back to full speed, which is what pressing play again asks for.
  void reset() {
    _interval = tick;
    _refusals = 0;
  }
}
