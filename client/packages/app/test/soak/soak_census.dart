// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The counters a soak run samples: open subscriptions, pending timers,
/// undisposed framework objects, live providers and rebuilds.
///
/// Each one counts what is open right now, and names where it was opened, so
/// a number that climbs between samples points at the code that opened it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final _appFrame = RegExp(r'package:(slimm_[a-z_]+/[^\s)]+\.dart):(\d+)');

/// The first frame of [stack] inside the app's own packages, as `file:line`.
String appOriginOf(StackTrace stack) {
  for (final line in stack.toString().split('\n')) {
    final match = _appFrame.firstMatch(line);
    if (match != null) return '${match.group(1)}:${match.group(2)}';
  }
  return 'outside the app';
}

/// Open things, each remembered by the stack that opened it.
class OriginCensus {
  final _open = <Object, StackTrace>{};

  int get count => _open.length;

  Object open(StackTrace stack) {
    final token = Object();
    _open[token] = stack;
    return token;
  }

  void close(Object token) => _open.remove(token);

  /// How many are open per origin; resolves stacks only now, since most close first.
  Map<String, int> byOrigin() {
    final counts = <String, int>{};
    for (final stack in _open.values) {
      final origin = appOriginOf(stack);
      counts[origin] = (counts[origin] ?? 0) + 1;
    }
    return counts;
  }
}

/// Counts timers created inside [run] that have neither fired nor been cancelled.
class TimerCensus {
  final pending = OriginCensus();

  /// Runs [body] in a zone whose timers are counted; they still run on the test's fake clock.
  R run<R>(R Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final token = pending.open(StackTrace.current);
        final inner = parent.createTimer(zone, duration, () {
          pending.close(token);
          callback();
        });
        return _CountedTimer(inner, () => pending.close(token));
      },
      createPeriodicTimer: (self, parent, zone, period, callback) {
        final token = pending.open(StackTrace.current);
        late final _CountedTimer counted;
        final inner = parent.createPeriodicTimer(
          zone,
          period,
          (_) => callback(counted),
        );
        return counted = _CountedTimer(inner, () => pending.close(token));
      },
    ),
  );
}

class _CountedTimer implements Timer {
  _CountedTimer(this._inner, this._closed);

  final Timer _inner;
  final void Function() _closed;

  @override
  void cancel() {
    _closed();
    _inner.cancel();
  }

  @override
  bool get isActive => _inner.isActive;
  @override
  int get tick => _inner.tick;
}

/// Framework objects created and not yet disposed, by class.
///
/// Fed by [FlutterMemoryAllocations], so it sees what the framework reports:
/// change notifiers, states, elements, render objects, layers, tickers,
/// images and pictures. Classes named in [traced] are also counted by where
/// they were created, which costs a stack walk per object.
class ObjectCensus {
  ObjectCensus({this.traced = const {}});

  final Set<String> traced;
  final alive = <String, int>{};
  final tracedAlive = <String, int>{};
  final _origins = Expando<String>();

  void start() => FlutterMemoryAllocations.instance.addListener(_on);
  void stop() => FlutterMemoryAllocations.instance.removeListener(_on);

  void _on(ObjectEvent event) {
    final name = event.object.runtimeType.toString();
    final step = switch (event) {
      ObjectCreated() => 1,
      ObjectDisposed() => -1,
      _ => 0,
    };
    if (step == 0) return;
    alive[name] = (alive[name] ?? 0) + step;
    if (!traced.contains(name)) return;
    final origin = step > 0
        ? _origins[event.object] = '$name at ${appOriginOf(StackTrace.current)}'
        : _origins[event.object];
    if (origin == null) return;
    tracedAlive[origin] = (tracedAlive[origin] ?? 0) + step;
  }

  int get total => alive.values.fold(0, (sum, n) => sum + n);
}

/// Widget rebuilds since the last [take], by widget class.
///
/// [takeRoots] counts only the widgets that asked to rebuild, not the ones
/// rebuilt because a parent did, so it names what started a rebuild.
class RebuildCensus {
  final _counts = <Type, int>{};
  final _roots = <Type, int>{};

  void start() => debugOnRebuildDirtyWidget = (element, _) {
    final type = element.widget.runtimeType;
    _counts[type] = (_counts[type] ?? 0) + 1;
    if (element.dirty && _hasBuilt(element)) {
      _roots[type] = (_roots[type] ?? 0) + 1;
    }
  };

  /// A first build has no child yet; the framework's own built-once flag is only kept while it prints rebuilds.
  static bool _hasBuilt(Element element) {
    var built = false;
    element.visitChildren((_) => built = true);
    return built;
  }

  void stop() => debugOnRebuildDirtyWidget = null;

  Map<String, int> take() => _drain(_counts);

  Map<String, int> takeRoots() => _drain(_roots);

  static Map<String, int> _drain(Map<Type, int> counts) {
    final taken = {for (final e in counts.entries) '${e.key}': e.value};
    counts.clear();
    return taken;
  }
}

/// Names each provider by what it produced and where it was first read,
/// since few of them carry a name.
class ProviderLabels extends ProviderObserver {
  final _labels = <Object, String>{};

  @override
  void didAddProvider(
    ProviderBase<Object?> provider,
    Object? value,
    ProviderContainer container,
  ) {
    final key = provider.from ?? provider;
    if (_labels.containsKey(key)) return;
    _labels[key] = provider.name ?? _describe(provider, value);
  }

  String _describe(ProviderBase<Object?> provider, Object? value) {
    final argument = provider.from == null
        ? ''
        : ' family(${provider.argument.runtimeType})';
    return '${value.runtimeType}$argument, first read at '
        '${appOriginOf(StackTrace.current)}';
  }

  /// Live provider elements of [container], by label.
  Map<String, int> count(ProviderContainer container) {
    final counts = <String, int>{};
    for (final element in container.getAllProviderElements()) {
      final provider = element.provider;
      final label =
          _labels[provider.from ?? provider] ?? '${provider.runtimeType}';
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts;
  }
}
