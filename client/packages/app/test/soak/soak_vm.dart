// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-class heap counts after a forced collection, read from the VM service.
///
/// Only there when the run was started with `flutter test --enable-vmservice`;
/// without it [VmProbe.connect] answers null and the run reports the other
/// counters alone.
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate' as iso;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Live instances and bytes of one class.
typedef ClassUse = ({int instances, int bytes});

class HeapSample {
  HeapSample(this.classes, this.heapBytes, this.rssBytes);

  /// Keyed `library::Class`.
  final Map<String, ClassUse> classes;
  final int heapBytes;
  final int rssBytes;
}

class VmProbe {
  VmProbe._(this._service, this._isolateId);

  final VmService _service;
  final String _isolateId;

  /// Call through `tester.runAsync`: the service answers in real time.
  static Future<VmProbe?> connect() async {
    final info = await developer.Service.getInfo();
    final uri = info.serverWebSocketUri;
    final isolateId = developer.Service.getIsolateId(iso.Isolate.current);
    if (uri == null || isolateId == null) return null;
    return VmProbe._(await vmServiceConnectUri(uri.toString()), isolateId);
  }

  /// Collects garbage, then counts what is left. Call through `tester.runAsync`.
  Future<HeapSample> sample() async {
    final profile = await _service.getAllocationProfile(_isolateId, gc: true);
    final classes = <String, ClassUse>{};
    for (final stat in profile.members ?? const <ClassHeapStats>[]) {
      final instances = stat.instancesCurrent ?? 0;
      if (instances == 0) continue;
      final ref = stat.classRef;
      final key = '${ref?.library?.uri ?? '?'}::${ref?.name ?? '?'}';
      classes[key] = (instances: instances, bytes: stat.bytesCurrent ?? 0);
    }
    return HeapSample(
      classes,
      profile.memoryUsage?.heapUsage ?? 0,
      ProcessInfo.currentRss,
    );
  }

  /// What keeps a few instances of [className] alive, one line per path from the instance outward.
  ///
  /// The way to tell a leak in the app from something the harness itself holds.
  Future<List<String>> retainers(String className, {int instances = 3}) async {
    final classes = await _service.getClassList(_isolateId);
    final lines = <String>[];
    for (final type in classes.classes ?? const <ClassRef>[]) {
      if (type.name != className) continue;
      final found = await _service.getInstances(
        _isolateId,
        type.id!,
        instances,
      );
      for (final instance in found.instances ?? const <ObjRef>[]) {
        final path = await _service.getRetainingPath(
          _isolateId,
          instance.id!,
          24,
        );
        lines.add(
          [
            for (final hop in path.elements ?? const <RetainingObject>[])
              _hop(hop),
          ].join(' <- '),
        );
      }
    }
    return lines;
  }

  static String _hop(RetainingObject hop) {
    final value = hop.value;
    final name = switch (value) {
      InstanceRef(:final classRef?) => classRef.name ?? '?',
      FieldRef(:final name?, :final ClassRef owner) =>
        'field $name of ${owner.name}',
      FieldRef(:final name?) => 'field $name',
      _ => value?.type ?? '?',
    };
    final key = hop.parentMapKey;
    final via =
        hop.parentField ?? (key is InstanceRef ? key.valueAsString : null);
    return via == null ? name : '$name.$via';
  }

  Future<void> close() => _service.dispose();
}
