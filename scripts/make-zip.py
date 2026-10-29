"""Deterministic zip: sorted entries, fixed timestamps, fixed modes.

usage: make-zip.py <out.zip> <root-dir> <epoch>
"""
import os
import sys
import time
import zipfile


def main() -> int:
    out, root, epoch = sys.argv[1], sys.argv[2], int(sys.argv[3])
    stamp = time.gmtime(epoch)[:6]
    names = []
    for base, _dirs, files in os.walk(root):
        for f in files:
            full = os.path.join(base, f)
            names.append(os.path.relpath(full, root).replace(os.sep, "/"))
    names.sort()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name in names:
            with open(os.path.join(root, name), "rb") as fh:
                data = fh.read()
            info = zipfile.ZipInfo(name, stamp)
            info.create_system = 3
            info.external_attr = (0o100644 << 16)
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    return 0


if __name__ == "__main__":
    sys.exit(main())
