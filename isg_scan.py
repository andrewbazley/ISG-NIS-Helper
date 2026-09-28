"""
ISG-NIS-Helper -- data-folder snapshot and diff.

What it does: walks the configured data roots and records, for each file,
its path, size and modification time. Two snapshots (start of session,
end of session) are compared to produce the list of files created,
modified or deleted during that session.

What it does NOT do, by design: open files, read file contents, move,
copy, rename, delete or lock anything. The only syscalls used are
scandir and stat. A snapshot cannot interfere with a running acquisition.
"""

import csv
import gzip
import os

from isg_common import ensure_dir


def _skip_dir(name, exclude_dirs):
    return name.lower() in exclude_dirs


def _wanted(name, include_extensions):
    if not include_extensions:
        return True
    return os.path.splitext(name)[1].lower() in include_extensions


def walk_roots(roots, exclude_dirs=(), include_extensions=(), follow_symlinks=False,
               stop_flag=None):
    """
    Yield (path, size, mtime_ns) for every file under roots.

    Per-entry errors (permission denied, file vanished mid-walk, a path
    longer than MAX_PATH) are skipped silently -- a snapshot is best
    effort and must never take the scope down with it.
    """
    exclude_dirs = set(d.lower() for d in exclude_dirs)
    include_extensions = set(include_extensions)

    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        stack = [root]
        while stack:
            if stop_flag is not None and stop_flag.is_set():
                return
            current = stack.pop()
            try:
                it = os.scandir(current)
            except Exception:
                continue
            with it:
                for entry in it:
                    try:
                        if entry.is_dir(follow_symlinks=follow_symlinks):
                            if not _skip_dir(entry.name, exclude_dirs):
                                stack.append(entry.path)
                            continue
                        if not entry.is_file(follow_symlinks=follow_symlinks):
                            continue
                        if not _wanted(entry.name, include_extensions):
                            continue
                        st = entry.stat(follow_symlinks=follow_symlinks)
                        yield (entry.path, st.st_size, st.st_mtime_ns)
                    except Exception:
                        continue


def write_manifest(path, rows):
    """Store a snapshot as a gzipped CSV. Returns the number of files."""
    ensure_dir(os.path.dirname(path))
    count = 0
    with gzip.open(path, "wt", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["path", "size", "mtime_ns"])
        for p, size, mtime in rows:
            w.writerow([p, size, mtime])
            count += 1
    return count


def read_manifest(path):
    """Load a snapshot back into {path: (size, mtime_ns)}."""
    data = {}
    try:
        with gzip.open(path, "rt", encoding="utf-8", newline="") as fh:
            r = csv.reader(fh)
            next(r, None)
            for row in r:
                if len(row) < 3:
                    continue
                try:
                    data[row[0]] = (int(row[1]), int(row[2]))
                except Exception:
                    continue
    except Exception:
        return {}
    return data


def snapshot(cfg, out_path, stop_flag=None):
    rows = walk_roots(cfg.data_roots,
                      exclude_dirs=cfg.exclude_dirs,
                      include_extensions=cfg.include_extensions,
                      follow_symlinks=cfg.follow_symlinks,
                      stop_flag=stop_flag)
    return write_manifest(out_path, rows)


def diff(start_path, end_path):
    """
    Compare two manifests.

    Returns (changes, summary) where changes is a list of
    (change_type, path, size, mtime_ns) and change_type is one of
    'new', 'modified', 'deleted'.
    """
    start = read_manifest(start_path)
    end = read_manifest(end_path)

    changes = []
    bytes_added = 0

    for path, (size, mtime) in end.items():
        prev = start.get(path)
        if prev is None:
            changes.append(("new", path, size, mtime))
            bytes_added += size
        elif prev[0] != size or prev[1] != mtime:
            changes.append(("modified", path, size, mtime))
            bytes_added += max(0, size - prev[0])

    for path, (size, mtime) in start.items():
        if path not in end:
            changes.append(("deleted", path, size, mtime))

    changes.sort(key=lambda c: (c[0], c[1].lower()))

    summary = {
        "files_at_start": len(start),
        "files_at_end": len(end),
        "files_new": sum(1 for c in changes if c[0] == "new"),
        "files_modified": sum(1 for c in changes if c[0] == "modified"),
        "files_deleted": sum(1 for c in changes if c[0] == "deleted"),
        "bytes_added": bytes_added,
    }
    return changes, summary


def write_detail_csv(path, changes, max_rows=50000):
    """Write the per-session file-change list. Returns (written, truncated)."""
    ensure_dir(os.path.dirname(path))
    truncated = len(changes) > max_rows
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["change", "path", "size_bytes", "mtime_ns"])
        for i, (kind, p, size, mtime) in enumerate(changes):
            if i >= max_rows:
                w.writerow(["TRUNCATED",
                            "%d further changes not listed" % (len(changes) - max_rows),
                            "", ""])
                break
            w.writerow([kind, p, size, mtime])
    return min(len(changes), max_rows), truncated
