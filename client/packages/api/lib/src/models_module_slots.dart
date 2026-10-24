// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a module shows in a slot, per `docs/decisions/0091-module-platform-phase-1-contracts.md`.
///
/// The server already validates slot content; this parser is a second line of
/// defence and never throws, so a hostile or newer payload can only shrink.
library;

/// The glyph names a slot may draw, the same closed list the bot UI uses.
const Set<String> kModuleSlotIcons = {
  'play',
  'pause',
  'stop',
  'skip_next',
  'skip_previous',
  'volume',
  'volume_off',
  'repeat',
  'shuffle',
  'list',
  'settings',
};

const int kModuleSlotMaxNodes = 40;
const int kModuleSlotMaxDepth = 4;
const int kModuleSlotMaxText = 120;
const int kModuleSlotMaxBadgeText = 24;

/// How loudly a text or badge reads. Anything unrecognised is [normal].
enum ModuleSlotTone {
  normal,
  muted,
  accent;

  static ModuleSlotTone parse(Object? value) => switch (value) {
        'muted' => ModuleSlotTone.muted,
        'accent' => ModuleSlotTone.accent,
        _ => ModuleSlotTone.normal,
      };
}

/// One display node. A client switches over the subtypes.
sealed class ModuleSlotNode {
  const ModuleSlotNode();
}

class ModuleSlotText extends ModuleSlotNode {
  const ModuleSlotText(this.text, {this.tone = ModuleSlotTone.normal});
  final String text;
  final ModuleSlotTone tone;
}

/// [name] is null when the module named a glyph this app does not have.
class ModuleSlotIcon extends ModuleSlotNode {
  const ModuleSlotIcon(this.name);
  final String? name;
}

class ModuleSlotBadge extends ModuleSlotNode {
  const ModuleSlotBadge(
    this.text, {
    this.icon,
    this.tone = ModuleSlotTone.normal,
  });
  final String text;
  final String? icon;
  final ModuleSlotTone tone;
}

/// [value] is already clamped into `0..max`, and [max] is above zero.
class ModuleSlotProgress extends ModuleSlotNode {
  const ModuleSlotProgress({
    required this.value,
    required this.max,
    this.label,
  });
  final double value;
  final double max;
  final String? label;
}

class ModuleSlotRow extends ModuleSlotNode {
  const ModuleSlotRow(this.children);
  final List<ModuleSlotNode> children;
}

class ModuleSlotStack extends ModuleSlotNode {
  const ModuleSlotStack(this.children);
  final List<ModuleSlotNode> children;
}

/// One member's slot content: the nodes to draw, or [fallback] text when
/// there are none.
class ModuleSlotItem {
  const ModuleSlotItem({this.nodes = const [], this.fallback});

  static const empty = ModuleSlotItem();

  final List<ModuleSlotNode> nodes;
  final String? fallback;

  bool get isEmpty => nodes.isEmpty && (fallback == null || fallback!.isEmpty);

  /// Reads the `{nodes, fallback}` shape; never throws.
  factory ModuleSlotItem.parse(Object? json) {
    if (json is! Map) return empty;
    final tag = json[r'$slim'];
    if (tag != null && tag != 'slot/1') return empty;
    final fallback = _text(json['fallback'], kModuleSlotMaxText);
    final raw = json['nodes'];
    if (raw is! List) return ModuleSlotItem(fallback: fallback);
    final walk = _Walk();
    final nodes = _parseList(raw, 1, walk);
    if (walk.overLimit) return ModuleSlotItem(fallback: fallback);
    return ModuleSlotItem(nodes: nodes, fallback: fallback);
  }
}

/// A profile section a module contributes for one member.
class ModuleProfileSection {
  const ModuleProfileSection({
    required this.moduleId,
    required this.name,
    required this.title,
    required this.item,
  });

  final String moduleId;
  final String name;

  /// The heading to show; the slot [name] when the module declared none.
  final String title;
  final ModuleSlotItem item;

  static ModuleProfileSection? tryParse(Object? json) {
    if (json is! Map) return null;
    final moduleId = json['module_id'];
    final name = json['name'];
    if (moduleId is! String || name is! String) return null;
    return ModuleProfileSection(
      moduleId: moduleId,
      name: name,
      title: _text(json['title'], kModuleSlotMaxText) ?? name,
      item: ModuleSlotItem.parse(json),
    );
  }
}

/// A badge a module shows beside a member's name.
class ModuleBadge {
  const ModuleBadge({
    required this.moduleId,
    required this.name,
    required this.item,
  });

  final String moduleId;
  final String name;
  final ModuleSlotItem item;

  static ModuleBadge? tryParse(Object? json) {
    if (json is! Map) return null;
    final moduleId = json['module_id'];
    final name = json['name'];
    if (moduleId is! String || name is! String) return null;
    return ModuleBadge(
      moduleId: moduleId,
      name: name,
      item: ModuleSlotItem.parse(json),
    );
  }
}

class _Walk {
  int seen = 0;
  bool overLimit = false;
}

List<ModuleSlotNode> _parseList(List<Object?> raw, int depth, _Walk walk) {
  final out = <ModuleSlotNode>[];
  for (final entry in raw) {
    if (walk.overLimit) break;
    if (entry is! Map) continue;
    walk.seen++;
    if (walk.seen > kModuleSlotMaxNodes || depth > kModuleSlotMaxDepth) {
      walk.overLimit = true;
      break;
    }
    final node = _parseNode(entry, depth, walk);
    if (node != null) out.add(node);
  }
  return out;
}

ModuleSlotNode? _parseNode(Map<Object?, Object?> json, int depth, _Walk walk) {
  switch (json['type']) {
    case 'text':
      final text = _text(json['text'], kModuleSlotMaxText);
      if (text == null) return null;
      return ModuleSlotText(text, tone: ModuleSlotTone.parse(json['tone']));
    case 'icon':
      return ModuleSlotIcon(_icon(json['name']));
    case 'badge':
      final text = _text(json['text'], kModuleSlotMaxBadgeText);
      if (text == null) return null;
      return ModuleSlotBadge(
        text,
        icon: _icon(json['icon']),
        tone: ModuleSlotTone.parse(json['tone']),
      );
    case 'progress':
      return _progress(json);
    case 'row':
      return ModuleSlotRow(_children(json, depth, walk));
    case 'stack':
      return ModuleSlotStack(_children(json, depth, walk));
  }
  return null;
}

List<ModuleSlotNode> _children(Map<Object?, Object?> json, int depth, _Walk w) {
  final raw = json['children'];
  return raw is List ? _parseList(raw, depth + 1, w) : const [];
}

ModuleSlotProgress? _progress(Map<Object?, Object?> json) {
  final value = json['value'];
  final max = json['max'];
  if (value is! num || max is! num) return null;
  if (!value.isFinite || !max.isFinite || max <= 0) return null;
  return ModuleSlotProgress(
    value: value.clamp(0, max).toDouble(),
    max: max.toDouble(),
    label: _text(json['label'], kModuleSlotMaxText),
  );
}

String? _icon(Object? name) =>
    name is String && kModuleSlotIcons.contains(name) ? name : null;

final RegExp _stripped = RegExp(
  '[\\u0000-\\u001F\\u007F-\\u009F\\u200B-\\u200F\\u202A-\\u202E'
  '\\u2060-\\u2069\\uFEFF]',
);

/// Strips control, zero-width and bidi characters, then truncates to [max]
/// code points; null when the input is not a string.
String? _text(Object? value, int max) {
  if (value is! String) return null;
  final clean = value.replaceAll(_stripped, '');
  final runes = clean.runes;
  if (runes.length <= max) return clean;
  return String.fromCharCodes(runes.take(max));
}
