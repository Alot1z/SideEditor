#!/usr/bin/env python3
"""Parse and validate an Xcode ``project.pbxproj`` (OpenStep / ASCII plist).

This is a real recursive-descent parser rather than a regex pass, so it reports
the first *syntactic* defect at an exact line:column, which is what Xcode's own
``xcodebuild -list`` / project loader reports only as

    The project 'X' is damaged and cannot be opened due to a parse error.

It then runs structural checks on the parsed object graph:

  a) duplicate object ids inside the ``objects`` dictionary
  b) object ids referenced but never defined
  c) missing required keys on PBXProject / targets / build configurations
  d) byte-level problems (BOM, NUL, bare CR, space-indented tabs)

Usage:
    python3 scripts/ci/pbxproj_lint.py AltStore.xcodeproj/project.pbxproj
    git cat-file -p HEAD:AltStore.xcodeproj/project.pbxproj | python3 scripts/ci/pbxproj_lint.py -

Exit code is 0 only when the file parses and no structural error is found.
"""

from __future__ import annotations

import re
import sys

OBJECT_ID = re.compile(r"^[0-9A-Fa-f]{24}$")


class ParseError(Exception):
    def __init__(self, message: str, line: int, col: int) -> None:
        super().__init__(f"{message} (line {line}, column {col})")
        self.message = message
        self.line = line
        self.col = col


class Dict:
    """An ordered dictionary that keeps every entry, including duplicates."""

    def __init__(self, line: int) -> None:
        self.line = line
        self.entries: list[tuple[str, object, int]] = []

    def get(self, key: str, default=None):
        for k, v, _ in reversed(self.entries):
            if k == key:
                return v
        return default

    def dupe_keys(self) -> list[str]:
        seen: set[str] = set()
        dupes: list[str] = []
        for k, _, _ in self.entries:
            if k in seen and k not in dupes:
                dupes.append(k)
            seen.add(k)
        return dupes

    def to_plain(self) -> dict:
        out: dict = {}
        for k, v, _ in self.entries:
            out[k] = v.to_plain() if isinstance(v, (Dict, Array)) else v
        return out

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Dict({len(self.entries)} entries @ line {self.line})"


class Array:
    def __init__(self, line: int) -> None:
        self.line = line
        self.items: list[tuple[object, int]] = []

    def to_plain(self) -> list:
        return [v.to_plain() if isinstance(v, (Dict, Array)) else v for v, _ in self.items]

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"Array({len(self.items)} items @ line {self.line})"


UNQUOTED = re.compile(r"[A-Za-z0-9_$/:.\-+]+")


class Parser:
    def __init__(self, text: str) -> None:
        self.text = text
        self.i = 0
        self.line = 1
        self.col = 1

    # -- low level ---------------------------------------------------------
    def peek(self) -> str:
        return self.text[self.i] if self.i < len(self.text) else ""

    def advance(self, n: int = 1) -> None:
        for _ in range(n):
            if self.i >= len(self.text):
                return
            if self.text[self.i] == "\n":
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.i += 1

    def error(self, message: str) -> ParseError:
        return ParseError(message, self.line, self.col)

    def skip_ws(self) -> None:
        while True:
            c = self.peek()
            # NB: `"" in " \t\r\n"` is True in Python, so EOF must be excluded
            # explicitly or skip_ws() spins forever at the end of the file.
            if c and c in " \t\r\n":
                self.advance()
            elif self.text.startswith("/*", self.i):
                end = self.text.find("*/", self.i + 2)
                if end == -1:
                    raise self.error("unterminated /* comment")
                self.advance(end + 2 - self.i)
            elif self.text.startswith("//", self.i):
                while self.peek() not in ("\n", ""):
                    self.advance()
            else:
                return

    # -- grammar -----------------------------------------------------------
    def parse_document(self) -> object:
        self.skip_ws()
        value = self.parse_value()
        self.skip_ws()
        if self.i != len(self.text):
            raise self.error(f"trailing content after root value: {self.text[self.i:self.i + 40]!r}")
        return value

    def parse_value(self) -> object:
        c = self.peek()
        if c == "{":
            return self.parse_dict()
        if c == "(":
            return self.parse_array()
        if c == '"':
            return self.parse_quoted()
        if c == "<":
            return self.parse_data()
        if not c:
            raise self.error("unexpected end of file, expected a value")
        return self.parse_unquoted()

    def parse_dict(self) -> Dict:
        node = Dict(self.line)
        self.advance()  # {
        while True:
            self.skip_ws()
            c = self.peek()
            if c == "}":
                self.advance()
                return node
            if not c:
                raise self.error(
                    f"unexpected end of file inside dictionary opened at line {node.line}; "
                    "missing '}'"
                )
            key_line = self.line
            if c == '"':
                key = self.parse_quoted()
            else:
                key = self.parse_unquoted()
            self.skip_ws()
            if self.peek() != "=":
                raise self.error(f"expected '=' after key {key!r}, found {self.describe_here()}")
            self.advance()  # =
            self.skip_ws()
            value = self.parse_value()
            self.skip_ws()
            if self.peek() != ";":
                raise self.error(
                    f"expected ';' after value for key {key!r}, found {self.describe_here()}"
                )
            self.advance()  # ;
            node.entries.append((key, value, key_line))

    def parse_array(self) -> Array:
        node = Array(self.line)
        self.advance()  # (
        while True:
            self.skip_ws()
            c = self.peek()
            if c == ")":
                self.advance()
                return node
            if not c:
                raise self.error(
                    f"unexpected end of file inside array opened at line {node.line}; missing ')'"
                )
            item_line = self.line
            item = self.parse_value()
            node.items.append((item, item_line))
            self.skip_ws()
            c = self.peek()
            if c == ",":
                self.advance()
                continue
            if c == ")":
                self.advance()
                return node
            raise self.error(f"expected ',' or ')' in array, found {self.describe_here()}")

    def parse_quoted(self) -> str:
        start_line, start_col = self.line, self.col
        self.advance()  # opening quote
        buf: list[str] = []
        while True:
            c = self.peek()
            if not c:
                raise ParseError("unterminated string literal", start_line, start_col)
            if c == '"':
                self.advance()
                return "".join(buf)
            if c == "\\":
                self.advance()
                esc = self.peek()
                mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
                buf.append(mapping.get(esc, esc))
                self.advance()
                continue
            buf.append(c)
            self.advance()

    def parse_data(self) -> str:
        start_line, start_col = self.line, self.col
        self.advance()  # <
        end = self.text.find(">", self.i)
        if end == -1:
            raise ParseError("unterminated data literal", start_line, start_col)
        raw = self.text[self.i:end]
        hexdigits = re.sub(r"\s+", "", raw)
        if not re.fullmatch(r"[0-9A-Fa-f]*", hexdigits) or len(hexdigits) % 2:
            raise self.error(f"malformed data literal <{raw.strip()}>")
        self.advance(end + 1 - self.i)
        return f"<{hexdigits}>"

    def parse_unquoted(self) -> str:
        m = UNQUOTED.match(self.text, self.i)
        if not m:
            raise self.error(f"unexpected character {self.peek()!r}, expected a token")
        token = m.group(0)
        self.advance(len(token))
        return token

    def describe_here(self) -> str:
        snippet = self.text[self.i:self.i + 24].replace("\n", "\\n")
        return f"{snippet!r}" if snippet else "end of file"


def byte_checks(raw: bytes) -> list[tuple[str, str]]:
    """Return (severity, message) pairs for byte-level problems.

    CR is only a warning: a CRLF working copy is a normal artifact of Git's
    checkout filters on Windows, while the blob CI checks out is what Xcode
    actually parses. BOM/NUL/trailing newline are real defects either way.
    """
    problems: list[tuple[str, str]] = []
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append(("ERROR", "file starts with a UTF-8 BOM"))
    if b"\x00" in raw:
        idx = raw.index(b"\x00")
        problems.append(("ERROR", f"file contains a NUL byte at offset {idx}"))
    if b"\r" in raw:
        line = raw[: raw.index(b"\r")].count(b"\n") + 1
        problems.append(
            ("WARN", f"file contains CR characters (first on line {line}); the committed blob should be LF only")
        )
    if not raw.endswith(b"\n"):
        problems.append(("ERROR", "file does not end with a newline"))
    for n, line in enumerate(raw.split(b"\n"), 1):
        stripped = line.lstrip(b" ")
        if stripped.startswith(b"\t") and line != stripped:
            problems.append(("WARN", f"line {n} mixes spaces before a tab in its indentation"))
            break
    return problems


REQUIRED_KEYS: dict[str, tuple[str, ...]] = {
    "PBXProject": ("isa", "mainGroup", "buildConfigurationList", "compatibilityVersion", "targets"),
    "PBXNativeTarget": ("isa", "buildConfigurationList", "buildPhases", "name", "productName", "productType"),
    "PBXAggregateTarget": ("isa", "buildConfigurationList", "buildPhases", "name", "productName"),
    "XCBuildConfiguration": ("isa", "buildSettings", "name"),
    "XCConfigurationList": ("isa", "buildConfigurations"),
    "PBXFileReference": ("isa", "path"),
    "PBXGroup": ("isa", "children"),
    # A PBXBuildFile points at a file directly (fileRef) or at a Swift package
    # product (productRef); either satisfies it.
    "PBXBuildFile": ("isa",),
    "PBXSourcesBuildPhase": ("isa", "files"),
    "PBXFrameworksBuildPhase": ("isa", "files"),
    "PBXResourcesBuildPhase": ("isa", "files"),
    "PBXCopyFilesBuildPhase": ("isa", "files"),
    "PBXShellScriptBuildPhase": ("isa", "shellScript"),
    "PBXTargetDependency": ("isa", "target"),
    "PBXContainerItemProxy": ("isa", "containerPortal"),
}


def iter_refs(value, path: str):
    """Yield (path, id, line) for every 24-character hex id in the graph."""
    if isinstance(value, Dict):
        for k, v, line in value.entries:
            yield from iter_refs(v, f"{path}.{k}", line)
    elif isinstance(value, Array):
        for v, line in value.items:
            yield from iter_refs(v, f"{path}[]", line)
    elif isinstance(value, str) and OBJECT_ID.match(value):
        yield path, value, 0


def collect_ids(value) -> list[tuple[str, int]]:
    found: list[tuple[str, int]] = []

    def walk(node) -> None:
        if isinstance(node, Dict):
            for _, v, _ in node.entries:
                walk(v)
        elif isinstance(node, Array):
            for v, _ in node.items:
                walk(v)
        elif isinstance(node, str) and OBJECT_ID.match(node):
            found.append((node, 0))

    walk(value)
    return found


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    target = argv[1]
    if target == "-":
        raw = sys.stdin.buffer.read()
        label = "<stdin>"
    else:
        with open(target, "rb") as fh:
            raw = fh.read()
        label = target

    print(f"== {label}: {len(raw)} bytes, {raw.count(bytes([10]))} newlines ==")

    errors = 0
    for severity, problem in byte_checks(raw):
        print(f"BYTE  {severity:<5} {problem}")
        if severity == "ERROR":
            errors += 1

    text = raw.decode("utf-8-sig", "replace")
    try:
        root = Parser(text).parse_document()
    except ParseError as exc:
        print(f"PARSE ERROR  {exc.message}")
        print(f"             at line {exc.line}, column {exc.col}")
        source_lines = text.splitlines()
        for n in range(max(1, exc.line - 2), min(len(source_lines), exc.line + 1) + 1):
            marker = ">>" if n == exc.line else "  "
            print(f"   {marker} {n:5d} | {source_lines[n - 1]}")
        return 1

    if not isinstance(root, Dict):
        print("PARSE ERROR  root object is not a dictionary")
        return 1
    print("PARSE  OK     root dictionary parsed")

    objects = root.get("objects")
    if not isinstance(objects, Dict):
        print("STRUCT ERROR root has no 'objects' dictionary")
        return 1

    version = root.get("objectVersion")
    compat = objects.get("compatibilityVersion") if False else None
    root_id = root.get("rootObject")
    print(f"INFO         objectVersion = {version}")
    print(f"INFO         archiveVersion = {root.get('archiveVersion')}")
    print(f"INFO         rootObject = {root_id}")
    print(f"INFO         objects = {len(objects.entries)} entries")

    # (b0) malformed object identifiers: Xcode ids are exactly 24 hex digits.
    for obj_id, body in objects.to_plain().items():
        if not OBJECT_ID.match(obj_id):
            looks_like_id = re.fullmatch(r"[0-9A-Fa-f-]{20,36}", obj_id or "")
            if looks_like_id:
                kind = "UUID with hyphens" if "-" in obj_id else f"{len(obj_id)} chars, not 24"
                print(
                    f"BADID     object key {obj_id!r} is not a valid 24-hex Xcode id "
                    f"({kind}); isa={body.get('isa') if isinstance(body, dict) else None}"
                )
                errors += 1

    # (a) duplicate object ids
    for key in objects.dupe_keys():
        lines = [ln for k, _, ln in objects.entries if k == key]
        print(f"DUPLICATE  id {key} defined {len(lines)} times at lines {lines}")
        errors += 1

    table = objects.to_plain()

    # (b) dangling references
    defined = set(table)
    referenced: dict[str, list[str]] = {}
    for obj_id, body in table.items():
        if not isinstance(body, dict):
            continue
        for path, ref, _ in iter_refs_dict(body, obj_id):
            referenced.setdefault(ref, []).append(path)
    for ref in sorted(referenced):
        if ref not in defined:
            where = ", ".join(sorted(set(referenced[ref]))[:4])
            print(f"DANGLING  {ref} referenced by {where} but never defined")
            errors += 1

    # (c) required keys
    for obj_id, body in table.items():
        if not isinstance(body, dict):
            print(f"STRUCT ERROR object {obj_id} is not a dictionary")
            errors += 1
            continue
        isa = body.get("isa")
        required = REQUIRED_KEYS.get(isa or "")
        if required is None:
            continue
        missing = [k for k in required if k not in body]
        if missing:
            print(f"MISSING   {isa} {obj_id} lacks required keys {missing}")
            errors += 1

    # root object sanity
    if root_id not in table:
        print(f"DANGLING  rootObject {root_id} is not defined in objects")
        errors += 1

    # quick target summary so the wiring is visible
    project = table.get(root_id) if isinstance(root_id, str) else None
    if isinstance(project, dict):
        print(f"INFO         compatibilityVersion = {project.get('compatibilityVersion')}")
        print(f"INFO         project targets = {project.get('targets')}")

    print(f"== {errors} error(s) ==" if errors else "== no errors ==")
    return 1 if errors else 0


def iter_refs_dict(body: dict, obj_id: str):
    for k, v in body.items():
        yield from _walk(v, f"{obj_id}.{k}")


def _walk(value, path: str):
    if isinstance(value, dict):
        for k, v in value.items():
            yield from _walk(v, f"{path}.{k}")
    elif isinstance(value, list):
        for v in value:
            yield from _walk(v, f"{path}[]")
    elif isinstance(value, str) and OBJECT_ID.match(value):
        yield path, value, 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
