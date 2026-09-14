#!/usr/bin/env python3
"""Name arithmetic for the backup tiers (portable-dotnet-architecture/proxmox-lab/RECOVERY.md).

Reads names on stdin and prints the ones the caller should delete, or the newest one and its age.
It never lists, deletes or uploads anything itself, so every retention rule is testable without a
node, a VM or a Digi account: `python3 -B -m unittest discover -s tests` from this directory.

  backup-retention.py wal-start <backup_manifest>   first WAL file a base backup needs
  backup-retention.py wal-prune <walfile>           WAL files logically before it
  backup-retention.py vzdump-prune <keep>           archives (and their .log/.notes) beyond the newest <keep> per VM
  backup-retention.py newest-prune <keep>           base-backup stamps beyond the newest <keep>
  backup-retention.py older-than <days>             stamped names older than <days>
  backup-retention.py newest-age <kind> [key]       "<name>\t<hours>" of the newest vzdump <vmid> | base | stamped <prefix>
"""
import calendar
import json
import re
import sys
import time

SEGMENT_BYTES = 16 * 1024 * 1024
WAL_FILE = re.compile(r"^([0-9A-F]{24})(?:\.partial|\.[0-9A-F]{8}\.backup)?\.zst$")
WAL_NAME = re.compile(r"^[0-9A-F]{24}$")
VZDUMP = re.compile(r"^vzdump-qemu-(\d+)-(\d{4})_(\d{2})_(\d{2})-(\d{2})_(\d{2})_(\d{2})\.vma\.zst$")
BASE = re.compile(r"^(\d{8}T\d{6}Z)/?$")
STAMP = re.compile(r"(\d{8})-(\d{6})")


def lsn_value(lsn):
    high, low = (int(part, 16) for part in lsn.split("/"))
    return (high << 32) | low


def segment_name(timeline, lsn):
    """The WAL file an LSN falls in, named the way Postgres names it (16 MB segments)."""
    number = lsn_value(lsn) // SEGMENT_BYTES
    per_id = 0x100000000 // SEGMENT_BYTES
    return f"{int(timeline):08X}{number // per_id:08X}{number % per_id:08X}"


def base_start_segment(manifest):
    """The first WAL file a base backup needs, from the WAL-Ranges of its backup_manifest."""
    first = min(manifest["WAL-Ranges"], key=lambda wal_range: lsn_value(wal_range["Start-LSN"]))
    return segment_name(first["Timeline"], first["Start-LSN"])


def wal_prune(names, cutoff):
    """WAL files logically before `cutoff`, compared the way pg_archivecleanup compares them: the
    timeline is ignored, and timeline history files are never candidates."""
    if not WAL_NAME.match(cutoff):
        raise ValueError(f"not a WAL file name: {cutoff!r}")
    for name in names:
        match = WAL_FILE.match(name)
        if match and match.group(1)[8:] < cutoff[8:]:
            yield name


def vzdump_prune(names, keep):
    """Archives beyond the newest `keep` per VM, each followed by its siblings (.log, .notes)."""
    names = list(names)
    per_vm = {}
    for name in names:
        match = VZDUMP.match(name)
        if match:
            per_vm.setdefault(match.group(1), []).append(name)
    for archives in per_vm.values():
        for archive in sorted(archives, reverse=True)[keep:]:
            stem = archive[: -len(".vma.zst")]
            yield archive
            yield from (name for name in names if name != archive and name.startswith(stem + "."))


def newest_prune(names, keep):
    """Base-backup stamps beyond the newest `keep`."""
    stamps = sorted({match.group(1) for match in map(BASE.match, names) if match}, reverse=True)
    yield from stamps[keep:]


def _local(text, pattern):
    return time.mktime(time.strptime(text, pattern))


def _utc(text, pattern):
    return calendar.timegm(time.strptime(text, pattern))


def older_than(names, days, now):
    for name in names:
        match = STAMP.search(name)
        if match and now - _local(match.group(1) + match.group(2), "%Y%m%d%H%M%S") > days * 86400:
            yield name


def newest_age(names, kind, key, now):
    """(name, age in hours) of the newest name of that kind, or None when there is none."""
    found = []
    for name in names:
        if kind == "vzdump":
            match = VZDUMP.match(name)
            if match and match.group(1) == key:
                found.append((_local("".join(match.group(2, 3, 4, 5, 6, 7)), "%Y%m%d%H%M%S"), name))
        elif kind == "base":
            match = BASE.match(name)
            if match:
                found.append((_utc(match.group(1), "%Y%m%dT%H%M%SZ"), match.group(1)))
        elif kind == "stamped":
            match = STAMP.search(name)
            if match and name.startswith(key):
                found.append((_local(match.group(1) + match.group(2), "%Y%m%d%H%M%S"), name))
        else:
            raise ValueError(f"unknown kind: {kind!r}")
    if not found:
        return None
    epoch, name = max(found)
    return name, (now - epoch) / 3600


def main(argv, stdin=sys.stdin, stdout=sys.stdout, now=None):
    now = time.time() if now is None else now
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command, args = argv[1], argv[2:]

    def names():
        return [line.strip() for line in stdin if line.strip()]

    if command == "wal-start":
        with open(args[0], encoding="utf-8") as manifest:
            print(base_start_segment(json.load(manifest)), file=stdout)
        return 0
    if command == "newest-age":
        result = newest_age(names(), args[0], args[1] if len(args) > 1 else "", now)
        if result:
            print(f"{result[0]}\t{result[1]:.1f}", file=stdout)
        return 0
    commands = {
        "wal-prune": lambda: wal_prune(names(), args[0]),
        "vzdump-prune": lambda: vzdump_prune(names(), int(args[0])),
        "newest-prune": lambda: newest_prune(names(), int(args[0])),
        "older-than": lambda: older_than(names(), float(args[0]), now),
    }
    if command not in commands:
        print(__doc__, file=sys.stderr)
        return 2
    for name in commands[command]():
        print(name, file=stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
