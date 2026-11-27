# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A reader for the OpenStep property list an `.xcodeproj` is written in.

No Xcode and no plutil on a Linux runner, so the gates that need to know what a
target builds, embeds and depends on parse the project instead of grepping it.
Reading only; the project is never written back out from here.
"""

import re

_TOKEN = re.compile(
    r"""\s+|/\*.*?\*/|//[^\n]*"""
    r"""|(?P<str>"(?:\\.|[^"\\])*")"""
    r"""|(?P<word>[A-Za-z0-9_./$+:\-]+)"""
    r"""|(?P<punct>[={}();,])""",
    re.S | re.X,
)


def _tokens(text: str):
    pos = 0
    while pos < len(text):
        match = _TOKEN.match(text, pos)
        if not match:
            raise ValueError(f"unreadable project text at offset {pos}: {text[pos:pos + 30]!r}")
        pos = match.end()
        if match.lastgroup == "str":
            yield "str", bytes(match.group("str")[1:-1], "utf-8").decode("unicode_escape")
        elif match.lastgroup == "word":
            yield "word", match.group("word")
        elif match.lastgroup == "punct":
            yield "punct", match.group("punct")


def parse(text: str):
    tokens = list(_tokens(text.split("\n", 1)[1] if text.startswith("// !$*UTF8*$!") else text))
    value, index = _value(tokens, 0)
    if index != len(tokens):
        raise ValueError("trailing text after the project's top-level value")
    return value


def _value(tokens, index):
    kind, token = tokens[index]
    if kind == "punct" and token == "{":
        return _dict(tokens, index + 1)
    if kind == "punct" and token == "(":
        return _list(tokens, index + 1)
    if kind in ("str", "word"):
        return token, index + 1
    raise ValueError(f"unexpected {token!r}")


def _dict(tokens, index):
    result = {}
    while tokens[index] != ("punct", "}"):
        key = tokens[index][1]
        if tokens[index + 1] != ("punct", "="):
            raise ValueError(f"no '=' after key {key!r}")
        result[key], index = _value(tokens, index + 2)
        if tokens[index] != ("punct", ";"):
            raise ValueError(f"no ';' after key {key!r}")
        index += 1
    return result, index + 1


def _list(tokens, index):
    items = []
    while tokens[index] != ("punct", ")"):
        item, index = _value(tokens, index)
        items.append(item)
        if tokens[index] == ("punct", ","):
            index += 1
    return items, index + 1


def objects(project):
    return project["objects"]


def target_named(project, name):
    for object_id, body in objects(project).items():
        if body.get("isa") == "PBXNativeTarget" and body.get("name") == name:
            return object_id, body
    raise KeyError(f"no target {name}")


def phase_files(project, target, isa):
    """The file references a target's build phase of kind [isa] compiles or copies, by name."""
    names = []
    for phase_id in target["buildPhases"]:
        phase = objects(project)[phase_id]
        if phase["isa"] != isa:
            continue
        for build_file_id in phase["files"]:
            ref = objects(project)[objects(project)[build_file_id]["fileRef"]]
            names.append(ref.get("path") or ref.get("name"))
    return names


def build_settings(project, target):
    """Per configuration name, the target's build settings."""
    configs = objects(project)[target["buildConfigurationList"]]["buildConfigurations"]
    return {objects(project)[c]["name"]: objects(project)[c]["buildSettings"] for c in configs}


def dependency_names(project, target):
    names = []
    for dep_id in target["dependencies"]:
        dep = objects(project)[dep_id]
        names.append(objects(project)[dep["target"]]["name"])
    return names


def every_reference_resolves(project):
    """Ids named anywhere in the project that no object defines."""
    defined = set(objects(project))
    missing = set()

    def walk(node, under_objects):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, under_objects)
        elif isinstance(node, list):
            for item in node:
                walk(item, under_objects)
        elif isinstance(node, str) and re.fullmatch(r"[0-9A-F]{24}", node) and node not in defined:
            missing.add(node)

    walk({k: v for k, v in project.items() if k != "objects"}, False)
    for body in objects(project).values():
        walk({k: v for k, v in body.items() if k != "remoteGlobalIDString"}, True)
    return missing
