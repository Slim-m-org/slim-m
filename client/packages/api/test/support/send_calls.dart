// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads the `_send(...)` call sites under lib/src back into the request keys
/// each one sends, for `request_contract_test.dart`.
///
/// Source-reading, so every file goes through `stripComments` first: a
/// commented-out call must not count as a request the client makes.
library;

import 'dart:io';

import 'code_only.dart';

/// What one call site sends. A null key set means the keys could not be read
/// from source (a spread, a loop, an unresolvable helper).
class SendCall {
  SendCall({
    required this.method,
    required this.path,
    required this.file,
    required this.line,
    this.bodyKeys,
    this.queryKeys,
    this.hasBody = false,
    this.hasQuery = false,
  });

  final String method;
  final String path;
  final String file;
  final int line;
  final bool hasBody;
  final bool hasQuery;
  final Set<String>? bodyKeys;
  final Set<String>? queryKeys;

  String get key => '$method ${placeholderInterpolations(path)}';
  String get where => '$file:$line';
}

/// Which model class declares the `toJson()` a call site passes as its body,
/// by route key: the receiver's type is not recoverable from source text.
typedef ToJsonOwners = Map<String, String>;

final RegExp _callStart = RegExp(r"_send\(\s*'([A-Z]+)'\s*,\s*'([^']*)'");

/// `/channels/$id/x` -> `/channels/{}/x`, matching the schema side's
/// placeholder form.
String placeholderInterpolations(String path) =>
    path.split('/').map((s) => s.contains(r'$') ? '{}' : s).join('/');

List<SendCall> extractSendCalls(Directory srcDir, ToJsonOwners toJsonOwners) {
  final files = srcDir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.dart'),
      );
  final texts = {
    for (final f in files)
      f.path.split('/').last: stripComments(f.readAsStringSync()),
  };
  final calls = <SendCall>[];
  for (final entry in texts.entries) {
    final text = entry.value;
    final name = entry.key;
    for (final m in _callStart.allMatches(text)) {
      final open = text.indexOf('(', m.start);
      final args = _splitTop(text.substring(open + 1, _closing(text, open)));
      String? body, query;
      for (final a in args) {
        final named =
            RegExp(r"^(body|query)\s*:\s*([\s\S]*)$").firstMatch(a.trim());
        if (named?.group(1) == 'body') body = named!.group(2)!.trim();
        if (named?.group(1) == 'query') query = named!.group(2)!.trim();
      }
      final route = '${m.group(1)} ${placeholderInterpolations(m.group(2)!)}';
      final scope = _Scope(text, m.start, toJsonOwners[route], texts.values);
      calls.add(SendCall(
        method: m.group(1)!,
        path: m.group(2)!,
        file: name,
        line: '\n'.allMatches(text.substring(0, m.start)).length + 1,
        hasBody: body != null,
        hasQuery: query != null,
        bodyKeys: body == null ? {} : scope.keysOf(body),
        queryKeys: query == null ? {} : scope.keysOf(query),
      ));
    }
  }
  return calls;
}

/// Resolves an argument expression to the string keys of the map(s) it can
/// evaluate to, looking through locals, ternaries and same-file helpers.
class _Scope {
  _Scope(this.text, this.at, this.toJsonOwner, this.allTexts);

  final Iterable<String> allTexts;
  final String text;
  final int at;
  final String? toJsonOwner;

  String get _method {
    final starts = RegExp(r'\n {2}(?![ }/])').allMatches(text.substring(0, at));
    return text.substring(starts.isEmpty ? 0 : starts.last.start, at);
  }

  Set<String>? keysOf(String expr, [int depth = 0]) {
    if (depth > 6) return null;
    var e = expr.trim();
    if (e.startsWith('const ')) e = e.substring(6).trim();
    if (e == 'null') return {};
    final ternary = _ternary(e);
    if (ternary != null) {
      return _union(ternary.map((b) => keysOf(b, depth + 1)));
    }
    if (RegExp(r'^(<[^{]*>)?\s*\{').hasMatch(e)) return _literalKeys(e);
    if (RegExp(r'^[a-z_]\w*$').hasMatch(e)) return _local(e, depth);
    final call = RegExp(r'^(_\w+)\(').firstMatch(e);
    if (call != null) return _helper(call.group(1)!, depth);
    if (e.endsWith('.toJson()') && toJsonOwner != null) {
      return _toJson(toJsonOwner!, depth);
    }
    return null;
  }

  Set<String>? _union(Iterable<Set<String>?> parts) {
    final out = <String>{};
    for (final p in parts) {
      if (p == null) return null;
      out.addAll(p);
    }
    return out;
  }

  Set<String>? _local(String name, int depth) {
    final window = _method;
    final decl =
        RegExp('\\b(?:final|var)\\s+(?:[\\w<>, ?]+\\s+)?$name\\s*=\\s*')
            .allMatches(window)
            .toList();
    if (decl.isEmpty) return null;
    final start = decl.last.end;
    final init = window.substring(start, _statementEnd(window, start));
    final keys = keysOf(init, depth + 1);
    if (keys == null) return null;
    final added = RegExp("\\b$name\\['([^']+)'\\]\\s*=").allMatches(window);
    if (RegExp('\\b$name\\.(addAll|update|remove)\\(').hasMatch(window)) {
      return null;
    }
    return {...keys, ...added.map((m) => m.group(1)!)};
  }

  Set<String>? _helper(String name, int depth) {
    final decl = RegExp('\\n[^\\n]*\\b$name\\([^)]*\\)\\s*(=>|\\{)')
        .allMatches(text)
        .toList();
    if (decl.isEmpty) return null;
    final end = decl.last.end;
    if (decl.last.group(1) == '=>') {
      return keysOf(text.substring(end, _statementEnd(text, end)), depth + 1);
    }
    final block = text.substring(end, _closing(text, end - 1));
    final returns = RegExp(r'return\s+([\s\S]*?);').allMatches(block);
    if (returns.isEmpty) return null;
    return _union(returns.map((r) => keysOf(r.group(1)!, depth + 1)));
  }

  Set<String>? _toJson(String owner, int depth) {
    for (final src in allTexts) {
      final cls = RegExp('class $owner\\b').firstMatch(src);
      if (cls == null) continue;
      final decl =
          RegExp(r'toJson\(\)\s*=>').firstMatch(src.substring(cls.end));
      if (decl == null) return null;
      final from = cls.end + decl.end;
      return _Scope(src, from, null, allTexts)
          .keysOf(src.substring(from, _statementEnd(src, from)), depth + 1);
    }
    return null;
  }
}

/// The `{ 'k': v, if (c) 'k2': v }` literal's top-level string keys; null if
/// an element is a spread, a loop or has a computed key.
Set<String>? _literalKeys(String literal) {
  final open = literal.indexOf('{');
  final inner = literal.substring(open + 1, _closing(literal, open));
  final keys = <String>{};
  for (var element in _splitTop(inner)) {
    var rest = element.trim();
    while (rest.startsWith('if') && RegExp(r'^if\s*\(').hasMatch(rest)) {
      final p = rest.indexOf('(');
      rest = rest.substring(_closing(rest, p) + 1).trim();
    }
    if (rest.isEmpty) continue;
    if (rest.startsWith('...{')) {
      final nested = _literalKeys(rest.substring(3));
      if (nested == null) return null;
      keys.addAll(nested);
      continue;
    }
    final key = RegExp(r"^'([^']*)'\s*:").firstMatch(rest);
    if (key == null) return null;
    keys.add(key.group(1)!);
  }
  return keys;
}

/// `a ? b : c` at depth 0 -> [b, c]; null when [e] is not a ternary.
List<String>? _ternary(String e) {
  final q = _topIndexOf(e, '?', 0);
  if (q < 0) return null;
  final c = _topIndexOf(e, ':', q + 1);
  if (c < 0) return null;
  return [e.substring(q + 1, c), e.substring(c + 1)];
}

int _topIndexOf(String s, String ch, int from) {
  var depth = 0;
  String? quote;
  for (var i = from; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == r'\') i++;
      if (c == quote) quote = null;
      continue;
    }
    if (c == "'") {
      quote = c;
    } else if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
    } else if (c == ch && depth == 0) {
      return i;
    }
  }
  return -1;
}

List<String> _splitTop(String s) {
  final parts = <String>[];
  var from = 0;
  for (var i = _topIndexOf(s, ',', 0); i >= 0; i = _topIndexOf(s, ',', from)) {
    parts.add(s.substring(from, i));
    from = i + 1;
  }
  if (s.substring(from).trim().isNotEmpty) parts.add(s.substring(from));
  return parts;
}

int _statementEnd(String s, int from) {
  final i = _topIndexOf(s, ';', from);
  return i < 0 ? s.length : i;
}

/// Index of the bracket closing the one at [open], string-aware.
int _closing(String s, int open) {
  var depth = 0;
  String? quote;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == r'\') i++;
      if (c == quote) quote = null;
      continue;
    }
    if (c == "'") {
      quote = c;
    } else if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
      if (depth == 0) return i;
    }
  }
  throw StateError('unbalanced bracket at $open');
}
