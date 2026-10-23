// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The slot/1 parser: it must never throw and may only shrink what it is given.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, dynamic> _text(String t, {Object? tone}) =>
    {'type': 'text', 'text': t, if (tone != null) 'tone': tone};

ModuleSlotItem _parse(List<Object?> nodes, {String? fallback}) =>
    ModuleSlotItem.parse({
      'nodes': nodes,
      if (fallback != null) 'fallback': fallback,
    });

Map<String, dynamic> _nest(int levels) {
  Map<String, dynamic> node = _text('leaf');
  for (var i = 0; i < levels; i++) {
    node = {
      'type': 'row',
      'children': [node],
    };
  }
  return node;
}

final _rlo = String.fromCharCode(0x202E);
final _lri = String.fromCharCode(0x2066);
final _lre = String.fromCharCode(0x202A);

void main() {
  test('a valid tree parses into typed nodes', () {
    final item = ModuleSlotItem.parse({
      r'$slim': 'slot/1',
      'nodes': [
        _text('Level 4', tone: 'accent'),
        {'type': 'icon', 'name': 'play'},
        {'type': 'badge', 'text': 'Pro', 'icon': 'list', 'tone': 'muted'},
        {'type': 'progress', 'value': 3, 'max': 10, 'label': 'XP'},
        {
          'type': 'stack',
          'children': [
            {
              'type': 'row',
              'children': [_text('a')],
            },
          ],
        },
      ],
      'fallback': 'Level 4',
    });
    expect(item.fallback, 'Level 4');
    final nodes = item.nodes;
    expect(nodes, hasLength(5));
    expect((nodes[0] as ModuleSlotText).tone, ModuleSlotTone.accent);
    expect((nodes[1] as ModuleSlotIcon).name, 'play');
    final badge = nodes[2] as ModuleSlotBadge;
    expect([badge.text, badge.icon, badge.tone],
        ['Pro', 'list', ModuleSlotTone.muted]);
    final progress = nodes[3] as ModuleSlotProgress;
    expect([progress.value, progress.max, progress.label], [3, 10, 'XP']);
    final row = (nodes[4] as ModuleSlotStack).children.single as ModuleSlotRow;
    expect((row.children.single as ModuleSlotText).text, 'a');
  });

  group('limits', () {
    test('40 nodes are kept, 41 leave only the fallback', () {
      final ok = _parse(List.generate(40, (i) => _text('$i')), fallback: 'fb');
      expect(ok.nodes, hasLength(40));
      final over =
          _parse(List.generate(41, (i) => _text('$i')), fallback: 'fb');
      expect(over.nodes, isEmpty);
      expect(over.fallback, 'fb');
    });

    test('nested children count towards the 40', () {
      final item = _parse([
        {
          'type': 'row',
          'children': List.generate(40, (i) => _text('$i')),
        },
      ], fallback: 'fb');
      expect(item.nodes, isEmpty);
      expect(item.fallback, 'fb');
    });

    test('depth 4 is kept, depth 5 leaves only the fallback', () {
      expect(_parse([_nest(3)], fallback: 'fb').nodes, hasLength(1));
      final over = _parse([_nest(4)], fallback: 'fb');
      expect(over.nodes, isEmpty);
      expect(over.fallback, 'fb');
    });

    test('text is truncated to 120, a badge to 24, the fallback to 120', () {
      final item = ModuleSlotItem.parse({
        'nodes': [
          _text('x' * 200),
          {'type': 'badge', 'text': 'y' * 50},
        ],
        'fallback': 'z' * 200,
      });
      expect((item.nodes[0] as ModuleSlotText).text, hasLength(120));
      expect((item.nodes[1] as ModuleSlotBadge).text, hasLength(24));
      expect(item.fallback, hasLength(120));
    });

    test('truncation counts code points, not UTF-16 units', () {
      final item = _parse([_text('\u{1F600}' * 130)]);
      expect((item.nodes.single as ModuleSlotText).text.runes, hasLength(120));
    });
  });

  group('values', () {
    test('an unknown tone becomes normal', () {
      final item = _parse([_text('a', tone: 'neon'), _text('b', tone: 5)]);
      expect(item.nodes.map((n) => (n as ModuleSlotText).tone),
          everyElement(ModuleSlotTone.normal));
    });

    test('an unknown icon draws nothing, for icons and badges', () {
      final item = _parse([
        {'type': 'icon', 'name': 'skull'},
        {'type': 'badge', 'text': 'x', 'icon': 'skull'},
      ]);
      expect((item.nodes[0] as ModuleSlotIcon).name, isNull);
      expect((item.nodes[1] as ModuleSlotBadge).icon, isNull);
    });

    test('progress needs numbers and a positive max', () {
      final item = _parse([
        {'type': 'progress', 'value': 1, 'max': 0},
        {'type': 'progress', 'value': 1, 'max': -5},
        {'type': 'progress', 'value': '1', 'max': 5},
        {'type': 'progress', 'value': 1},
      ]);
      expect(item.nodes, isEmpty);
    });

    test('progress value is clamped into 0..max', () {
      final item = _parse([
        {'type': 'progress', 'value': 99, 'max': 10},
        {'type': 'progress', 'value': -4, 'max': 10},
      ]);
      expect((item.nodes[0] as ModuleSlotProgress).value, 10);
      expect((item.nodes[1] as ModuleSlotProgress).value, 0);
    });

    test('control, zero-width and bidi characters are stripped', () {
      final item = ModuleSlotItem.parse({
        'nodes': [
          _text('a\u0000b\nc${_rlo}d​e${_lri}f\u0085g'),
          {'type': 'badge', 'text': 'x\u0007y'},
        ],
        'fallback': 'h${_lre}i',
      });
      expect((item.nodes[0] as ModuleSlotText).text, 'abcdefg');
      expect((item.nodes[1] as ModuleSlotBadge).text, 'xy');
      expect(item.fallback, 'hi');
    });
  });

  group('unknown and malformed input', () {
    test('an unknown type is skipped and the rest kept', () {
      final item = _parse([
        {'type': 'hologram'},
        _text('kept'),
      ], fallback: 'fb');
      expect(item.nodes, hasLength(1));
    });

    test('all nodes unknown leaves no nodes and the fallback', () {
      final item = _parse([
        {'type': 'hologram'},
      ], fallback: 'fb');
      expect(item.nodes, isEmpty);
      expect(item.fallback, 'fb');
      expect(item.isEmpty, isFalse);
    });

    test('all nodes unknown with no fallback is empty', () {
      final item = _parse([
        {'type': 'hologram'},
      ]);
      expect(item.isEmpty, isTrue);
    });

    test('a wrong \$slim tag yields an empty item', () {
      final item = ModuleSlotItem.parse({
        r'$slim': 'slot/2',
        'nodes': [_text('a')],
        'fallback': 'fb',
      });
      expect(item.nodes, isEmpty);
      expect(item.fallback, isNull);
    });

    test('non-object input never throws', () {
      for (final bad in <Object?>[null, 3, 'x', <Object?>[], true]) {
        expect(ModuleSlotItem.parse(bad).isEmpty, isTrue);
      }
    });

    test('null and wrong-typed fields never throw', () {
      final item = ModuleSlotItem.parse({
        'nodes': [
          null,
          7,
          'x',
          {'type': 5},
          {'type': 'text', 'text': null},
          {'type': 'text', 'text': 9},
          {'type': 'badge'},
          {'type': 'row', 'children': 'nope'},
          {'type': 'icon', 'name': 3},
          {'type': 'progress', 'value': 1, 'max': 2, 'label': 8},
        ],
        'fallback': 12,
      });
      expect(item.fallback, isNull);
      expect(item.nodes.whereType<ModuleSlotText>(), isEmpty);
      expect((item.nodes.last as ModuleSlotProgress).label, isNull);
      expect(ModuleSlotItem.parse({'nodes': 'nope'}).nodes, isEmpty);
    });
  });

  group('route payloads', () {
    test('a profile section falls back to its name for the title', () {
      final s = ModuleProfileSection.tryParse({
        'module_id': 'xp',
        'name': 'level',
        'nodes': [_text('4')],
      })!;
      expect([s.moduleId, s.name, s.title], ['xp', 'level', 'level']);
      expect(s.item.nodes, hasLength(1));
      final titled = ModuleProfileSection.tryParse({
        'module_id': 'xp',
        'name': 'level',
        'title': 'Level',
        'nodes': <Object>[],
      })!;
      expect(titled.title, 'Level');
    });

    test('an entry without module_id or name is dropped', () {
      expect(ModuleProfileSection.tryParse({'name': 'a'}), isNull);
      expect(ModuleBadge.tryParse({'module_id': 'a'}), isNull);
      expect(ModuleBadge.tryParse('x'), isNull);
    });
  });
}
