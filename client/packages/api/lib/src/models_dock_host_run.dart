// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A host-run connector (decision 0134): a connector whose image the host runs
/// in a sandbox through the operator's supervisor.
library;

/// One `host:port` a connector may reach through its gateway.
class EgressHost {
  const EgressHost({required this.host, required this.port});

  final String host;
  final int port;

  factory EgressHost.fromJson(Map<String, dynamic> json) =>
      EgressHost(host: json['host'] as String, port: json['port'] as int);

  Map<String, dynamic> toJson() => {'host': host, 'port': port};

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is EgressHost && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// What a host-run connector asks the host to run, shown at consent.
class HostRunAsk {
  const HostRunAsk({
    required this.image,
    required this.egress,
    required this.egressPrivate,
    required this.volume,
    this.memoryMib,
    this.cpus,
    this.pids,
  });

  /// The image, pinned by digest.
  final String image;
  final List<EgressHost> egress;

  /// Whether it asks for the Private network, which a LAN address needs.
  final bool egressPrivate;

  /// Whether it asks for a data volume.
  final bool volume;

  /// Null takes the supervisor's default.
  final int? memoryMib;
  final double? cpus;
  final int? pids;

  factory HostRunAsk.fromJson(Map<String, dynamic> json) {
    final limits = (json['limits'] as Map<String, dynamic>?) ?? const {};
    return HostRunAsk(
      image: json['image'] as String,
      egress: [
        for (final e in (json['egress'] as List<dynamic>? ?? const []))
          EgressHost.fromJson(e as Map<String, dynamic>),
      ],
      egressPrivate: json['egress_private'] as bool? ?? false,
      volume: json['volume'] as bool? ?? false,
      memoryMib: limits['memory_mib'] as int?,
      cpus: (limits['cpus'] as num?)?.toDouble(),
      pids: limits['pids'] as int?,
    );
  }
}

/// The host-run ask in a manifest's `connector` section, or null.
HostRunAsk? dockHostRunAsk(Map<String, dynamic> manifest) {
  final connector = manifest['connector'];
  if (connector is! Map<String, dynamic>) return null;
  final hostRun = connector['host_run'];
  return hostRun is Map<String, dynamic> ? HostRunAsk.fromJson(hostRun) : null;
}

/// What the admin approved of a host-run ask at install.
class HostRunApproval {
  const HostRunApproval({required this.egress, this.egressPrivate = false});

  final List<EgressHost> egress;
  final bool egressPrivate;

  Map<String, dynamic> toJson() => {
        'egress': [for (final e in egress) e.toJson()],
        'egress_private': egressPrivate,
      };
}

/// Whether this server can run connectors (`GET /space/dock/connector-runtime`).
class ConnectorRuntimeStatus {
  const ConnectorRuntimeStatus({
    required this.configured,
    required this.available,
    this.detail,
  });

  final bool configured;
  final bool available;

  /// Why it is unavailable.
  final String? detail;

  factory ConnectorRuntimeStatus.fromJson(Map<String, dynamic> json) =>
      ConnectorRuntimeStatus(
        configured: json['configured'] as bool,
        available: json['available'] as bool,
        detail: json['detail'] as String?,
      );
}

/// A host-run connector's state as the admin sees it.
enum HostRunState {
  running,
  stopped,
  crashed,
  disabledAfterCrashes,
  refused,
  starting,
  runtimeUnavailable,
  unknown;

  static HostRunState parse(String? wire) => switch (wire) {
        'running' => running,
        'stopped' => stopped,
        'crashed' => crashed,
        'disabled_after_crashes' => disabledAfterCrashes,
        'refused' => refused,
        'starting' => starting,
        'runtime_unavailable' => runtimeUnavailable,
        _ => unknown,
      };
}

/// `GET /space/dock/modules/{id}/host-run`.
class ConnectorHostRun {
  const ConnectorHostRun({
    required this.state,
    required this.ask,
    required this.restarts,
    this.exitCode,
    this.oomKilled = false,
    this.lastError,
  });

  final HostRunState state;

  /// What it was approved to run.
  final HostRunAsk ask;

  /// Crashes in the last 10 minutes.
  final int restarts;
  final int? exitCode;
  final bool oomKilled;

  /// Why it is not running.
  final String? lastError;

  factory ConnectorHostRun.fromJson(Map<String, dynamic> json) =>
      ConnectorHostRun(
        state: HostRunState.parse(json['state'] as String?),
        ask: HostRunAsk.fromJson(json),
        restarts: json['restarts'] as int? ?? 0,
        exitCode: json['exit_code'] as int?,
        oomKilled: json['oom_killed'] as bool? ?? false,
        lastError: json['last_error'] as String?,
      );
}

/// One line of a host-run connector's output.
class HostRunLogLine {
  const HostRunLogLine({
    required this.ts,
    required this.stream,
    required this.text,
  });

  final String ts;

  /// `stdout` or `stderr`.
  final String stream;
  final String text;

  factory HostRunLogLine.fromJson(Map<String, dynamic> json) => HostRunLogLine(
        ts: json['ts'] as String,
        stream: json['stream'] as String,
        text: json['text'] as String,
      );
}
