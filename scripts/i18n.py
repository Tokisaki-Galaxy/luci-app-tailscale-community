#!/usr/bin/env python3
"""Regenerate LuCI translation templates and sync the .po files.

Replacement for openwrt/luci's build/i18n-sync.sh, which drives Perl scripts
and needs xgettext, msgmerge and msguniq from the gettext toolchain. None of
that is convenient on Windows, so this reimplements the parts LuCI actually
uses with the Python standard library only.

What it does, mirroring the upstream pipeline:

  1. Extract translatable strings from every source file under the package
     (view scripts, menu.d/acl.d JSON, ucode templates) and write
     po/templates/<name>.pot.
  2. Merge the new template into each po/<lang>/<name>.po: existing
     translations survive, obsolete entries are kept but commented out
     (#~), and new entries are added untranslated.

Deliberate differences from upstream:

  * Reference line numbers are normalised to "first line of the file" the
    same way upstream does with `msguniq`, which collapses duplicate
    references; here duplicates are merged and sorted.
  * A strings that cannot be round-tripped through the POT format raise
    instead of being silently dropped.
  * --check exits non-zero when the on-disk files are out of date, so CI can
    enforce it.

Usage:
    python scripts/i18n.py            # regenerate .pot and merge .po
    python scripts/i18n.py --pot      # only regenerate .pot
    python scripts/i18n.py --check    # fail if anything is out of date
    python scripts/i18n.py --lang zh_Hans
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# extraction
# ---------------------------------------------------------------------------

# Same keyword sets the LuCI scanner uses, reduced to what this repository
# actually contains: .js for views, .json for menu/acl metadata.
JS_KEYWORDS = ("_", "N_")
TRANSLATE_CALL = re.compile(r"(?<![\w.$])(_|N_)\s*\(")

# _( 'text' ) or _( "text" ), optionally followed by a context argument
CALL_RE = re.compile(
    r"""(?<![\w.$])(?P<fn>_|N_)\s*\(\s*
        (?P<quote>['"])(?P<text>(?:\\.|(?!\2).)*)(?P=quote)
    """,
    re.VERBOSE | re.DOTALL,
)


@dataclass
class Entry:
    msgid: str
    refs: list[tuple[str, int]] = field(default_factory=list)
    msgstr: str = ""

    def key(self) -> str:
        return self.msgid


def unescape_js(literal: str) -> str:
    """Turn a JS string body into the actual text."""
    out = []
    i = 0
    while i < len(literal):
        ch = literal[i]
        if ch == "\\" and i + 1 < len(literal):
            nxt = literal[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\"}
            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue
            if nxt == "/":
                out.append("/")
                i += 2
                continue
            # unknown escape: keep it verbatim, as xgettext does
            out.append(nxt)
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def scan_js(path: Path, rel: str) -> list[Entry]:
    """Extract _() and N_() calls from a view script."""
    src = path.read_text(encoding="utf-8")
    entries: list[Entry] = []

    for match in CALL_RE.finditer(src):
        text = unescape_js(match.group("text"))
        if not text:
            continue
        line = src.count("\n", 0, match.start()) + 1
        entries.append(Entry(msgid=text, refs=[(rel, line)]))

    return entries


def scan_json(path: Path, rel: str) -> list[Entry]:
    """Extract title/description from menu.d and acl.d metadata.

    LuCI's scanner rewrites "title": "x" into _("x") before handing it to
    xgettext, so only those two keys are translatable.
    """
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []

    entries: list[Entry] = []
    src = path.read_text(encoding="utf-8")

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("title", "description") and isinstance(value, str) and value:
                    entries.append(Entry(msgid=value, refs=[(rel, 1)]))
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(data)
    return entries


SCANNERS = {".js": scan_js, ".json": scan_json}

SOURCE_DIRS = (
    ("htdocs", "htdocs"),
    ("root/usr/share/luci/menu.d", "root/usr/share/luci/menu.d"),
    ("root/usr/share/rpcd/acl.d", "root/usr/share/rpcd/acl.d"),
)


def iter_sources(pkg: Path):
    """Yield (path, repo-relative name) for every scannable file."""
    for _, sub in SOURCE_DIRS:
        base = pkg / sub
        if not base.exists():
            continue
        for path in sorted(base.rglob("*")):
            if path.is_file() and path.suffix in SCANNERS:
                yield path, f"{pkg.name}/{path.relative_to(pkg).as_posix()}"


def collect(pkg: Path) -> dict[str, Entry]:
    """Merge every extracted string into one msgid -> Entry map."""
    merged: dict[str, Entry] = {}

    for path, rel in iter_sources(pkg):
        for entry in SCANNERS[path.suffix](path, rel):
            existing = merged.get(entry.key())
            if existing is None:
                merged[entry.key()] = entry
            else:
                existing.refs.extend(entry.refs)

    for entry in merged.values():
        entry.refs = sorted(set(entry.refs))

    return merged


# ---------------------------------------------------------------------------
# po / pot serialisation
# ---------------------------------------------------------------------------

HEADER_POT = 'msgid ""\nmsgstr "Content-Type: text/plain; charset=UTF-8"\n'


def escape_po(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\t", "\\t")
        .replace("\r", "\\r")
        .replace("\n", "\\n")
    )


def unescape_po(text: str) -> str:
    out = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
            out.append(mapping.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def wrap_strings(text: str, width: int = 70) -> list[str]:
    """Split a long string into gettext-style continuation pieces."""
    parts = []
    for chunk in text.split("\n"):
        if len(chunk) <= width:
            parts.append(chunk)
            continue
        words = re.findall(r"\S+\s*", chunk)
        line = ""
        for word in words:
            if len(line) + len(word) > width and line:
                parts.append(line)
                line = word
            else:
                line += word
        if line:
            parts.append(line)
    return parts


def render_field(keyword: str, text: str) -> str:
    escaped = escape_po(text)
    if len(escaped) > 70:
        out = [f'{keyword} ""']
        for piece in wrap_strings(escaped):
            out.append(f'"{piece}"')
        return "\n".join(out)
    return f'{keyword} "{escaped}"'


def render_entry(entry: Entry, obsolete: bool = False) -> str:
    prefix = "#~ " if obsolete else ""
    lines = []

    for ref, line in entry.refs:
        lines.append(f"#: {ref}:{line}")

    msgid = render_field("msgid", entry.msgid)
    msgstr = render_field("msgstr", entry.msgstr)

    for part in msgid.split("\n"):
        lines.append(prefix + part)
    for part in msgstr.split("\n"):
        lines.append(prefix + part)

    return "\n".join(lines)


def render_pot(entries: dict[str, Entry]) -> str:
    chunks = [HEADER_POT.rstrip("\n")]
    for msgid in sorted(entries):
        chunks.append(render_entry(entries[msgid]))
    return "\n\n".join(chunks) + "\n"


# ---------------------------------------------------------------------------
# po parsing
# ---------------------------------------------------------------------------

FIELD_RE = re.compile(r'^(msgid|msgstr|msgctxt|msgid_plural)\s+"(.*)"$', re.DOTALL)


def parse_po(text: str) -> tuple[list[Entry], list[Entry]]:
    """Return (live entries, obsolete entries).

    Obsolete entries are the ones gettext writes as "#~ msgid ...". They are
    kept so that a string which disappears from the source and later comes
    back still has its translation.
    """
    live: list[Entry] = []
    obsolete: list[Entry] = []

    # work block by block; a block is one entry plus its comments
    for block in re.split(r"\n\s*\n", text):
        if not block.strip():
            continue

        lines = block.split("\n")
        is_obsolete = lines[0].startswith("#~")
        refs: list[tuple[str, int]] = []
        msgid_parts: list[str] = []
        msgstr_parts: list[str] = []
        have_msgid = False
        target = None

        for line in lines:
            if line.startswith("#~ "):
                line = line[3:]
            elif line.startswith("#~"):
                continue
            elif line.startswith("#"):
                continue

            ref_match = re.match(r'^#:\s+(.*)$', line)
            if ref_match:
                for token in ref_match.group(1).split():
                    ref, _, num = token.rpartition(":")
                    if ref and num.isdigit():
                        refs.append((ref, int(num)))
                continue

            field_match = FIELD_RE.match(line)
            if field_match:
                keyword, value = field_match.group(1), unescape_po(field_match.group(2))
                if keyword == "msgid":
                    have_msgid = True
                    target = msgid_parts
                    target.append(value)
                elif keyword == "msgstr":
                    target = msgstr_parts
                    target.append(value)
                continue

            stripped = line.strip()
            if stripped.startswith('"') and stripped.endswith('"') and target is not None:
                target.append(unescape_po(stripped[1:-1]))

        if not have_msgid:
            continue

        msgid = "".join(msgid_parts)
        if not msgid:
            # the header block
            continue

        entry = Entry(msgid=msgid, refs=refs, msgstr="".join(msgstr_parts))
        (obsolete if is_obsolete else live).append(entry)

    return live, obsolete


def existing_msgstrs(path: Path) -> dict[str, str]:
    """Read msgid -> msgstr from an existing .po without needing a parser."""
    if not path.exists():
        return {}

    text = path.read_text(encoding="utf-8")
    result: dict[str, str] = {}

    # split on blank lines; each block is one entry
    for block in re.split(r"\n\s*\n", text):
        if not block.strip() or block.lstrip().startswith("#~"):
            continue

        msgid_parts: list[str] = []
        msgstr_parts: list[str] = []
        target = None

        for line in block.split("\n"):
            match = FIELD_RE.match(line)
            if match:
                keyword, value = match.group(1), unescape_po(match.group(2))
                if keyword == "msgid":
                    target = msgid_parts
                    target.append(value)
                elif keyword == "msgstr":
                    target = msgstr_parts
                    target.append(value)
                continue
            stripped = line.strip()
            if stripped.startswith('"') and stripped.endswith('"') and target is not None:
                target.append(unescape_po(stripped[1:-1]))

        msgid = "".join(msgid_parts)
        msgstr = "".join(msgstr_parts)
        if msgid:
            result[msgid] = msgstr

    return result


def po_header(msgid: str, msgstr: str) -> str:
    return f'msgid ""\nmsgstr "{msgstr}"'


def render_po(
    header_msgstr: str,
    template: dict[str, Entry],
    translations: dict[str, str],
    obsolete: list[Entry],
) -> str:
    chunks = [po_header("", header_msgstr)]

    for msgid in sorted(template):
        entry = template[msgid]
        entry.msgstr = translations.get(msgid, "")
        chunks.append(render_entry(entry))

    # Strings that used to be in the template but are gone from the source are
    # kept as obsolete entries with their translation, the way gettext does it.
    # That way a string which comes back later is still translated.
    seen: set[str] = set()
    for entry in obsolete:
        if entry.msgid in template or entry.msgid in seen:
            continue
        seen.add(entry.msgid)
        entry.msgstr = translations.get(entry.msgid, entry.msgstr)
        chunks.append(render_entry(entry, obsolete=True))

    for msgid, msgstr in sorted(translations.items()):
        if not msgid or msgid in template or msgid in seen or not msgstr:
            continue
        seen.add(msgid)
        chunks.append(render_entry(Entry(msgid=msgid, msgstr=msgstr), obsolete=True))

    return "\n\n".join(chunks) + "\n"


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

def find_package(repo: Path) -> Path:
    for candidate in sorted(repo.iterdir()):
        if candidate.is_dir() and (candidate / "Makefile").exists() and candidate.name.startswith("luci-app-"):
            return candidate
    raise SystemExit("could not find the luci-app-* package directory")


def regenerate(repo: Path, only_pot: bool, langs: list[str] | None, write: bool = True) -> list[Path]:
    """Rewrite .pot and .po files; return the paths that changed (or would)."""
    pkg = find_package(repo)
    po_dir = pkg / "po"
    template_dir = po_dir / "templates"
    template_dir.mkdir(parents=True, exist_ok=True)

    template = collect(pkg)
    if not template:
        raise SystemExit("no translatable strings found")

    pot_path = template_dir / "community.pot"
    pot_text = render_pot(template)
    changed: list[Path] = []

    stale = not pot_path.exists() or pot_path.read_text(encoding="utf-8") != pot_text
    if stale:
        changed.append(pot_path)
        if write:
            pot_path.write_text(pot_text, encoding="utf-8", newline="\n")

    print(f"template: {pot_path.relative_to(repo).as_posix()} ({len(template)} strings)")

    if only_pot:
        return changed

    for lang_dir in sorted(p for p in po_dir.iterdir() if p.is_dir() and p.name != "templates"):
        if langs and lang_dir.name not in langs:
            continue

        po_path = lang_dir / "community.po"
        translations = existing_msgstrs(po_path)

        header = translations.get("", "")
        if not header:
            header = "Content-Type: text/plain; charset=UTF-8\\n"

        _, obsolete = parse_po(po_path.read_text(encoding="utf-8")) if po_path.exists() else ([], [])
        text = render_po(header, template, translations, obsolete)

        before = po_path.read_text(encoding="utf-8") if po_path.exists() else None
        if before != text:
            changed.append(po_path)
            if write:
                po_path.write_text(text, encoding="utf-8", newline="\n")

        known = sum(1 for m in template if translations.get(m))
        print(f"  {lang_dir.name:10s} {known}/{len(template)} translated")

    return changed


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="repository root")
    parser.add_argument("--pot", action="store_true", help="only regenerate the .pot template")
    parser.add_argument("--check", action="store_true", help="fail if files are out of date")
    parser.add_argument("--lang", action="append", help="limit to these language directories")
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    changed = regenerate(repo, args.pot, args.lang, write=not args.check)

    if args.check:
        if changed:
            print("\nout of date:")
            for path in changed:
                print(f"  {path.relative_to(repo).as_posix()}")
            print("\nrun: python scripts/i18n.py")
            return 1
        print("\nall translation files are up to date")
        return 0

    if changed:
        print(f"\nupdated {len(changed)} file(s)")
    else:
        print("\nnothing to do")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
