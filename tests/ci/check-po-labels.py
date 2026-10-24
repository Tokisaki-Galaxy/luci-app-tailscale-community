#!/usr/bin/env python3
"""Check that help text cites labels the user can actually find on the form.

Step-by-step guides in this package say "click X". If the po files translate
that quoted X differently from the label itself, the guide points at text that
is not on the page and the user cannot follow it. That happened once with the
Traditional Chinese "Auto Configure Firewall" label, which the Site-to-Site
guide called 自動配置防火牆 while the button read 自動設定防火牆.

The rule enforced here: every quoted span inside a numbered help step must be
the translation of some label that this view actually renders. Which strings
look like steps is taken from the template; each language is then checked
against its own catalog, so a translation cannot introduce a span that maps to
nothing. Languages are discovered from the po directory rather than listed, so
a new translation cannot land unchecked.

Exit status is 0 when every quoted span resolves, 1 otherwise.
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PO_DIR = os.path.join(ROOT, 'luci-app-tailscale-community', 'po')

# Labels the view renders, as the English msgid that holds their translation.
# Keep this in step with the `_('...')` label strings in the view. Every entry
# must still exist in the template, which is checked below: a rename would
# otherwise shrink the set of known labels and let bad quotes through.
#
# 'Exit Node' is deliberately absent. It is a real label, but it is also the
# name of a control in the Tailscale client, so a step that says "choose it
# under Exit Node" can point at the wrong screen while still matching. Steps
# that mean the client's setting say so in prose instead of quoting it.
FORM_LABELS = [
    'Accept Routes',
    'Advertise Exit Node',
    'Advertise Routes',
    'Auto Configure Firewall',
]


def language_dirs():
    """Every po directory except the template one.

    Derived from the tree rather than listed, so a new translation cannot land
    unchecked. scripts/i18n.py works the same way.
    """
    names = sorted(n for n in os.listdir(PO_DIR)
                   if n != 'templates'
                   and os.path.isdir(os.path.join(PO_DIR, n)))
    if not names:
        raise SystemExit(f'no translation directories under {PO_DIR}')
    return names


# A quoted span counts as a label when it appears inside a span like "X" or
# 「X」. Straight quotes are kept as escaped quotes in the po source, so they
# are matched after the escapes have been turned back into characters.
QUOTE_RE = re.compile(r'"([^"\n]+)"|「([^」\n]+)」|“([^”\n]+)”')


def parse_po(path):
    """Return {msgid: msgstr} for a po or pot file.

    Written by hand rather than with polib: the CI image has gettext but not
    necessarily the python bindings, and a msgid may span several lines.
    """
    with io.open(path, encoding='utf-8') as fh:
        txt = fh.read()

    out = {}
    for block in re.split(r'\n[ \t]*\n', txt):
        if block.lstrip().startswith('#~'):
            continue

        mid, mstr = [], []
        cur = None
        saw_id = saw_str = False

        for line in block.split('\n'):
            s = line.strip()
            if s.startswith('msgid '):
                cur, saw_id = mid, True
                v = s[len('msgid '):]
                if v.startswith('"') and v.endswith('"'):
                    cur.append(v[1:-1].replace('\\"', '"'))
            elif s.startswith('msgstr '):
                cur, saw_str = mstr, True
                v = s[len('msgstr '):]
                if v.startswith('"') and v.endswith('"'):
                    cur.append(v[1:-1].replace('\\"', '"'))
            elif s.startswith('"') and s.endswith('"') and cur is not None:
                cur.append(s[1:-1].replace('\\"', '"'))
            else:
                cur = None

        key = ''.join(mid)
        if saw_id and saw_str and key:
            out[key] = ''.join(mstr)

    return out


def is_step(msgid):
    """A numbered help line, e.g. "2. Click ...". Headings and prose are not."""
    return bool(re.match(r'^\d+\. ', msgid))


def quoted_spans(text):
    found = []
    for group in QUOTE_RE.findall(text):
        for span in group:
            if span:
                found.append(span)
    return found


def main():
    template = parse_po(os.path.join(PO_DIR, 'templates', 'community.pot'))
    steps = [k for k in template if is_step(k)]
    if not steps:
        print('no numbered help steps found in the template')
        return 1

    problems = []

    # A label renamed in the view and not here would silently drop out of the
    # known set, which loosens the check instead of failing it.
    for label in FORM_LABELS:
        if label not in template:
            problems.append(
                f'label {label!r} is listed as a form label but is not in the '
                f'template; the view and this list have drifted apart')

    langs = language_dirs()

    for lang in langs:
        path = os.path.join(PO_DIR, lang, 'community.po')
        if not os.path.exists(path):
            problems.append(f'{lang}: directory has no community.po')
            continue
        catalog = parse_po(path)

        known = {catalog[label] for label in FORM_LABELS
                 if label in catalog and catalog[label]}
        if not known:
            problems.append(f'{lang}: none of the form labels are translated')
            continue

        checked = 0
        for msgid in steps:
            translated = catalog.get(msgid, '')
            if not translated:
                continue
            for span in quoted_spans(translated):
                checked += 1
                if span not in known:
                    problems.append(
                        f'{lang}: step quotes {span!r}, which is not a label '
                        f'on the form\n    {translated}')

        # Without this the whole check passes vacuously if the guides stop
        # quoting their labels, which is exactly when it should be reviewed.
        if checked == 0:
            problems.append(
                f'{lang}: no quoted label found in any step; either the guides '
                f'lost their quotes or the step detection broke')

        print(f'{lang:9s} {checked:2d} quoted label(s) checked, '
              f'{len(known)} label(s) known')

    if problems:
        print()
        for p in problems:
            print(p)
        print(f'\n{len(problems)} problem(s)')
        return 1

    print('\nall quoted labels resolve')
    return 0


if __name__ == '__main__':
    sys.exit(main())
