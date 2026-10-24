"""Reject workflow files that contain a duplicated key.

GitHub only reports a duplicate key as a 422 when it tries to parse the file,
which is far away from the commit that introduced it. PyYAML silently keeps
the last value, so a plain yaml.safe_load does not notice either.
"""
import glob
import sys

import yaml


class Strict(yaml.SafeLoader):
    pass


def no_duplicates(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ValueError('duplicate key: %r' % (key,))
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)

failed = False
for path in sorted(glob.glob('.github/workflows/*.yml')):
    try:
        yaml.load(open(path, encoding='utf-8'), Loader=Strict)
        print('ok:', path)
    except Exception as exc:
        print('::error::%s: %s' % (path, exc))
        failed = True

sys.exit(1 if failed else 0)
