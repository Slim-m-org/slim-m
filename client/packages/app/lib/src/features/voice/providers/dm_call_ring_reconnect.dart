// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps DM call rings across a dropped socket, which a ring outlives.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' as api;

import 'dm_call_ring_state.dart';

/// What [DmCallRingReconnect] needs from the ring controller.
class DmCallRingReconnectHost {
  const DmCallRingReconnectHost({
    required this.read,
    required this.write,
    required this.isMounted,
    required this.listIncoming,
    required this.restorable,
    required this.dropIncoming,
    required this.loadChannel,
  });

  final DmCallRingState Function() read;
  final void Function(DmCallRingState) write;
  final bool Function() isMounted;
  final Future<List<api.OutstandingDmCallRing>> Function() listIncoming;
  final bool Function(api.OutstandingDmCallRing) restorable;
  final void Function() dropIncoming;
  final void Function(String channelId) loadChannel;
}

/// The incoming ring is settled by re-reading the outstanding rings once the
/// socket is live; the outgoing one by its own end frame, or by the caller no
/// longer being alone in the call. Neither outlives the server's ring timeout.
class DmCallRingReconnect {
  DmCallRingReconnect(this._host, {required this.ringTimeout});

  final DmCallRingReconnectHost _host;
  final Duration ringTimeout;

  String? _incoming;
  String? _outgoing;
  Timer? _expiry;
  int _generation = 0;

  /// Marks both current rings as carried across a reconnect.
  void hold() {
    _generation++;
    final state = _host.read();
    _incoming = state.incoming?.ringId;
    _outgoing = state.outgoing?.ringId;
    _expiry?.cancel();
    _expiry = _incoming == null && _outgoing == null
        ? null
        : Timer(ringTimeout, _dropCarried);
  }

  /// Settles the incoming ring from the server's list of outstanding rings.
  Future<void> settleIncoming() async {
    final generation = ++_generation;
    List<api.OutstandingDmCallRing>? rings;
    try {
      rings = await _host.listIncoming();
    } catch (error, stack) {
      // Not only ApiException: this runs unawaited, so nothing else would catch it.
      api.reportFailure(
        api.LogTag.voice,
        'look up ringing calls',
        error,
        stack,
      );
    }
    if (!_host.isMounted() || generation != _generation) return;
    final carried = _incoming;
    _incoming = null;
    final current = _host.read().incoming;
    // A ring that arrived on the live socket is newer than this read.
    if (current != null && current.ringId != carried) return;
    final outstanding = rings?.where(_host.restorable).toList() ?? const [];
    if (outstanding.isEmpty) {
      if (current != null) _host.dropIncoming();
      return;
    }
    final kept = outstanding.firstWhere(
      (ring) => ring.ringId == carried,
      orElse: () => outstanding.first,
    );
    if (kept.ringId == current?.ringId) return;
    _host.write(
      _host.read().copyWith(
        incoming: IncomingDmCallRing(
          channelId: kept.channelId,
          ringId: kept.ringId,
          callerId: kept.callerId,
        ),
      ),
    );
    _host.loadChannel(kept.channelId);
  }

  /// Ends a carried outgoing ring once [stillCalling] says it is over.
  void settleOutgoing({required bool Function(String channelId) stillCalling}) {
    final ring = _host.read().outgoing;
    if (ring == null || ring.ringId != _outgoing) return;
    if (stillCalling(ring.channelId)) return;
    _outgoing = null;
    _host.write(_host.read().copyWith(clearOutgoing: true));
  }

  void _dropCarried() {
    if (!_host.isMounted()) return;
    if (_incoming != null && _host.read().incoming?.ringId == _incoming) {
      _host.dropIncoming();
    }
    if (_outgoing != null && _host.read().outgoing?.ringId == _outgoing) {
      _host.write(_host.read().copyWith(clearOutgoing: true));
    }
    _forgetCarried();
  }

  /// Forgets what was carried, and any read still in flight.
  void forget() {
    _generation++;
    _forgetCarried();
  }

  void _forgetCarried() {
    _incoming = null;
    _outgoing = null;
    _expiry?.cancel();
    _expiry = null;
  }
}
