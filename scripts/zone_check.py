#!/usr/bin/env python3
"""Fails when public text holds something that looks private.

Checks every tracked file, and with --messages <range> those commits' messages,
or with --stdin the text piped in. These are generic patterns. A private
denylist, one case-insensitive regular expression per line, can be supplied
through the DEVMATE_PRIVATE_DENYLIST environment variable; its contents and the
text it matches are never printed.
"""

import os
import re
import subprocess
import sys

SKIPPED = {"LICENSE", "scripts/zone_check.py"}
ALLOWED_EMAIL = re.compile(
    r"@(example\.(com|org|net|invalid)|([a-z0-9-]+\.)*noreply\.github\.com)$", re.I
)
ALLOWED_OWNERS = {"focusedsystems", "example", "user-attachments", "gonzalezreal"}
ALLOWED_HOME = {"me", "example"}

PATTERNS = [
    (
        "email address",
        re.compile(r"[A-Za-z0-9._%+\-\[\]]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"),
        lambda m: not ALLOWED_EMAIL.search(m.group(0)),
    ),
    (
        "GUID",
        re.compile(
            r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I
        ),
        None,
    ),
    (
        "home folder",
        re.compile(r"/(?:Users|home)/([A-Za-z0-9._-]+)"),
        lambda m: m.group(1).lower() not in ALLOWED_HOME,
    ),
    (
        "private address",
        re.compile(
            r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b"
        ),
        None,
    ),
    (
        "GitHub owner",
        re.compile(r"github\.com[/:]([A-Za-z0-9_.-]+)", re.I),
        lambda m: m.group(1).lower() not in ALLOWED_OWNERS,
    ),
]


def private_patterns():
    path = os.environ.get("DEVMATE_PRIVATE_DENYLIST")
    if not path:
        return []
    with open(path, encoding="utf-8") as handle:
        lines = [line.strip() for line in handle]
    return [
        re.compile(line, re.I) for line in lines if line and not line.startswith("#")
    ]


def findings(text, label, denylist):
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for name, pattern, keep in PATTERNS:
            for match in pattern.finditer(line):
                if keep is None or keep(match):
                    found.append(f"{label}:{number}: {name}: {match.group(0)}")
        if any(pattern.search(line) for pattern in denylist):
            found.append(f"{label}:{number}: matches the private denylist")
    return found


def git(*arguments):
    return subprocess.run(["git", *arguments], check=True, capture_output=True).stdout


def tracked_files(denylist):
    found = []
    for raw in git("ls-files", "-z").split(b"\0"):
        path = raw.decode()
        if not path or path in SKIPPED or not os.path.isfile(path):
            continue
        with open(path, "rb") as handle:
            data = handle.read()
        if b"\0" in data:
            continue
        found += findings(path, "path", denylist)
        found += findings(data.decode("utf-8", "replace"), path, denylist)
    return found


def self_test():
    bad = [
        "someone@" + "company.test",
        "12345678-1234-1234-1234-1234567890ab",
        "/Users/" + "someone/x",
        "192.168." + "1.2",
        "github.com/" + "someorg/repo",
    ]
    good = [
        "person@example.com",
        "/Users/example/x",
        "github.com/focusedsystems/devmate",
        "1+bot@users.noreply.github.com",
    ]
    failed = [text for text in bad if not findings(text, "t", [])]
    failed += [text for text in good if findings(text, "t", [])]
    if failed:
        print("zone check self-test failed:", failed)
        return 1
    print("zone check self-test passed")
    return 0


def main(arguments):
    if arguments == ["--self-test"]:
        return self_test()
    denylist = private_patterns()
    if arguments == ["--stdin"]:
        found = findings(sys.stdin.read(), "stdin", denylist)
    elif len(arguments) == 2 and arguments[0] == "--messages":
        found = findings(
            git("log", "--format=%B", arguments[1]).decode("utf-8", "replace"),
            "commits",
            denylist,
        )
    elif not arguments:
        found = tracked_files(denylist)
    else:
        print("usage: zone_check.py [--self-test | --stdin | --messages <range>]")
        return 2
    for line in found:
        print(line)
    if found:
        print(f"{len(found)} possible private detail(s). DevMate is public.")
        return 1
    print("zone check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
