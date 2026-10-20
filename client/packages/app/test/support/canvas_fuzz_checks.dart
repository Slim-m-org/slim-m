// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The invariants `canvas_engine_fuzz_test.dart` holds each client to, and the
/// report that names every distinct way a run broke them.
library;

import 'dart:io';

import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_fuzz_server.dart';
import 'canvas_fuzz_world.dart';

class FuzzViolation {
  FuzzViolation(this.seed, this.tick, this.detail, this.trace);

  final int seed;
  final int tick;
  final String detail;
  final List<String> trace;
  int seeds = 1;
}

/// Collects violations by category: the first example in full, the count of
/// seeds that hit each.
class FuzzReport {
  FuzzReport([this.label = 'run']);

  /// Names the trace files, so two configurations never overwrite each other.
  final String label;
  final Map<String, FuzzViolation> byCategory = {};
  final Set<String> _countedFor = {};

  void add(FuzzWorld world, String category, String detail) {
    final existing = byCategory[category];
    if (existing != null) {
      if (_countedFor.add('$category#${world.seed}')) existing.seeds++;
      return;
    }
    _countedFor.add('$category#${world.seed}');
    final trace = world.trace;
    byCategory[category] = FuzzViolation(
      world.seed,
      world.tickNo,
      detail,
      trace.length > 40 ? trace.sublist(trace.length - 40) : [...trace],
    );
    _dump(world);
  }

  void _dump(FuzzWorld world) {
    final dir = Platform.environment['CANVAS_FUZZ_TRACE_DIR'];
    if (dir == null) return;
    Directory(dir).createSync(recursive: true);
    File('$dir/$label-seed-${world.seed}.trace').writeAsStringSync(
      '${world.trace.join('\n')}\n',
    );
  }

  String render() {
    final out = StringBuffer('${byCategory.length} distinct violation(s):\n');
    for (final entry in byCategory.entries) {
      final v = entry.value;
      out
        ..writeln('\n[${entry.key}] seeds=${v.seeds} first seed=${v.seed} tick=${v.tick}')
        ..writeln('  ${v.detail}')
        ..writeln('  trace tail:');
      for (final line in v.trace) {
        out.writeln('    $line');
      }
    }
    return out.toString();
  }
}

/// Live ids the document holds, from the spatial grid itself.
List<String> gridLiveIds(CanvasDocument document) {
  final out = CullResult();
  document.scene.queryRect(-1e9, -1e9, 1e9, 1e9, out);
  return [
    for (final slot in out.slots)
      if (document.strokeIfAlive(slot) case final stroke?) stroke.id,
  ];
}

/// Checks that hold at every instant, mid-flight.
void checkInternal(FuzzWorld world, FuzzClient client, FuzzReport report) {
  final document = client.engine.document;
  document.refresh();
  final ids = gridLiveIds(document);
  final unique = ids.toSet();
  final who = client.userId;
  if (ids.length != unique.length) {
    report.add(world, 'internal: one id is held twice', '$who grid ids=$ids');
  }
  final counts = document.liveCountsByKind;
  final total = counts.strokes + counts.images + counts.notes + counts.shapes;
  if (document.objectCount.value != total) {
    report.add(
      world,
      'internal: objectCount drifted from the live objects',
      '$who objectCount=${document.objectCount.value} live=$total',
    );
  }
  final slots = document.paintOrder.toList();
  final painted = <String>[];
  for (final slot in slots) {
    final stroke = document.strokeIfAlive(slot);
    if (stroke == null) {
      report.add(world, 'internal: paint order holds a dead slot', '$who slot $slot');
    } else {
      painted.add(stroke.id);
    }
  }
  for (var i = 1; i < slots.length; i++) {
    if (document.strokeIfAlive(slots[i]) != null &&
        document.strokeIfAlive(slots[i - 1]) != null &&
        document.comparePaintOrder(slots[i - 1], slots[i]) > 0) {
      report.add(world, 'internal: paint order is not sorted', '$who ${painted.take(6)}');
      break;
    }
  }
  if (painted.length != painted.toSet().length ||
      !unique.containsAll(painted)) {
    report.add(world, 'internal: painted something that is not live', '$who painted=$painted live=$unique');
  }
  for (final entry in {
    'selected': document.selectedObjectId.value,
    'elevated': document.elevatedObjectId.value,
  }.entries) {
    final id = entry.value;
    if (id != null && !document.isAlive(id)) {
      report.add(
        world,
        'internal: the ${entry.key} object is not live',
        '$who ${entry.key}=$id isAlive=false',
      );
    }
  }
}

/// What the server says an object looks like, to compare a client with.
String _serverView(FuzzObject o) =>
    '${o.kind} (${o.x.toStringAsFixed(1)}, ${o.y.toStringAsFixed(1)}) '
    '${o.w.toStringAsFixed(1)}x${o.h.toStringAsFixed(1)} z=${o.z} seq=${o.seq}'
    '${o.kind == 'note' ? ' text="${o.props['text']}"' : ''}';

/// Compares one client with the server after everything has settled.
/// Returns the categories it reported, for the caller to classify.
Set<String> checkAgainstServer(
  FuzzWorld world,
  FuzzClient client,
  FuzzReport report, {
  required String prefix,
}) => checkDocumentAgainstServer(
  world,
  client.engine.document,
  client.userId,
  report,
  prefix: prefix,
);

Set<String> checkDocumentAgainstServer(
  FuzzWorld world,
  CanvasDocument document,
  String who,
  FuzzReport report, {
  required String prefix,
}) {
  document.refresh();
  final reported = <String>{};
  void flag(String category, String detail) {
    reported.add(category);
    report.add(world, '$prefix$category', '$who: $detail');
  }

  final server = world.server;
  final live = {for (final o in server.liveObjects) o.id: o};
  final held = gridLiveIds(document).toSet();
  for (final id in live.keys.where((id) => !held.contains(id))) {
    final o = server.objects[id]!;
    flag('missing: the server has it, the client does not show it', '$id ${_serverView(o)} tombstoned/known=${document.knows(id)}');
  }
  for (final id in held.where((id) => !live.containsKey(id))) {
    final o = server.objects[id];
    flag(
      'ghost: the client shows it, the server does not have it live',
      '$id server=${o == null ? 'unknown' : (o.live ? 'live' : 'removed')} ${o == null ? '' : _serverView(o)}',
    );
  }
  for (final o in live.values.where((o) => held.contains(o.id))) {
    final b = document.objectBounds(o.id)!;
    if ((b.x - o.x).abs() > 1e-6 ||
        (b.y - o.y).abs() > 1e-6 ||
        (b.w - o.w).abs() > 1e-6 ||
        (b.h - o.h).abs() > 1e-6) {
      flag(
        'position: client box differs from the server',
        '${o.id} client=(${b.x.toStringAsFixed(1)}, ${b.y.toStringAsFixed(1)}) ${b.w.toStringAsFixed(1)}x${b.h.toStringAsFixed(1)} server=${_serverView(o)}',
      );
    }
    final z = document.zIndexOf(o.id);
    if (z != o.z) {
      flag('z-index: client paint order differs from the server', '${o.id} client z=$z server=${_serverView(o)}');
    }
    if (o.kind == 'note' && document.noteTextOf(o.id) != o.props['text']) {
      flag('note text: client differs from the server', '${o.id} client="${document.noteTextOf(o.id)}" server="${o.props['text']}"');
    }
  }
  return reported;
}
