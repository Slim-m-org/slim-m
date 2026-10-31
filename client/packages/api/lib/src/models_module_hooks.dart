// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One hook an installed module has placed in front of an action, with its
/// place in the chain and how it has been doing, per
/// `docs/decisions/0100-module-safety-contracts.md`.
library;

class ModuleHook {
  const ModuleHook({
    required this.moduleId,
    required this.moduleName,
    required this.kind,
    required this.hook,
    required this.phase,
    required this.priority,
    required this.failClosed,
    required this.live,
    this.reads = const [],
    this.runs = 0,
    this.failures = 0,
    this.lastError,
    this.lastFuelUsed,
    this.maxFuelUsed = 0,
  });

  final String moduleId;
  final String moduleName;

  /// `interceptor` or `permission`.
  final String kind;

  /// The message hook point, or the action a permission hook stands in front of.
  final String hook;

  /// `reject`, `annotate` or `rewrite` for an interceptor; empty otherwise.
  final String phase;
  final List<String> reads;

  /// Lower runs first within a phase.
  final int priority;

  /// Whether a failure refuses the action instead of letting it through.
  final bool failClosed;

  /// Whether it is in the chain now.
  final bool live;
  final int runs;
  final int failures;
  final String? lastError;
  final int? lastFuelUsed;
  final int maxFuelUsed;

  factory ModuleHook.fromJson(Map<String, dynamic> json) => ModuleHook(
        moduleId: json['module_id'] as String,
        moduleName: json['module_name'] as String,
        kind: json['kind'] as String,
        hook: json['hook'] as String,
        phase: json['phase'] as String? ?? '',
        reads: [
          for (final field in json['reads'] as List<dynamic>? ?? const [])
            field as String,
        ],
        priority: json['priority'] as int,
        failClosed: json['fail_closed'] as bool? ?? false,
        live: json['live'] as bool? ?? false,
        runs: json['runs'] as int? ?? 0,
        failures: json['failures'] as int? ?? 0,
        lastError: json['last_error'] as String?,
        lastFuelUsed: json['last_fuel_used'] as int?,
        maxFuelUsed: json['max_fuel_used'] as int? ?? 0,
      );
}
