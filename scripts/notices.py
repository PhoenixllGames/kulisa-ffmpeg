"""Third party notices of the FFmpeg code that is compiled into this build.

usage: notices.py <ffmpeg-build-dir> <notices-out> <log-out> <title>

Maps every compiled object (*.o) of the FFmpeg build tree back to its source file and to every file of
the tree it includes: the compiler dependency file (.d) of the object, plus a scan of the include lines
of assembly, CUDA and resource files and of sources without a dependency file. Then reads every comment
block of those files:
  - the standard FFmpeg LGPL 2.1 or later grant is recognized and needs no notice (LICENSE.txt);
  - a block with any other license text must match a known permissive license (IJG, BSD, MIT, ISC,
    zlib, public domain) and is copied verbatim into the notices file;
  - any other license text, and any GPL text, stops the build.
Objects of host tools (ffbuild/) are not part of the shipped binaries and are skipped.
"""
import os
import re
import sys

SOURCE_EXTS = (".c", ".asm", ".S", ".cu", ".cpp", ".rc", ".m")
HOST_DIRS = ("ffbuild/",)

# Standard FFmpeg (and Libav) LGPL 2.1 or later header, matched on lower case text with collapsed
# whitespace. Each part is removed from a block; what remains is checked for other license text.
WHO = r"(?:ffmpeg|libav\w*|libsw\w*|this library|this program|this file|the library|it)"
LGPL_PARTS = [
    r"this file is part of (?:ffmpeg|libav\w*|libsw\w*)\.?",
    WHO + r" is free software;? you can redistribute it and/or modify it under the terms of the gnu "
    r"lesser general public license as published by the free software foundation;? either version "
    r"2\.1 of the license, or \(at your option\) any later version\.",
    WHO + r" is distributed in the hope that it will be useful, but without any warranty;? without even "
    r"the implied warranty of merchantability or fitness for a particular purpose\.? see the gnu lesser "
    r"general public license for more details\.",
    r"you should have received a copy of the gnu lesser general public license along with " + WHO +
    r"(?:;? if not, (?:write to the free software foundation, inc\.,? .{0,80}?usa|see <[^>]*>))?\.?",
]
# Phrases that mark license text (doc comments that only say "license" or "permitted" do not count).
LICENSE_WORDS = re.compile(
    r"permission is hereby granted|redistribution and use|permission to use, copy|is free software|"
    r"general public licen|public domain|licensed under|spdx-license-identifier|all rights reserved|"
    r"without any warranty|warranties of merchantability|provided ['\"]?as[- ]is|"
    r"independent jpeg group|software licen[cs]e|bsd[- ]licen|\(new\) bsd licen|mit licen|"
    r"apache licen|licen[cs]e,? version|distributed under|copyleft|\bgpl\b|\blgpl\b",
    re.I,
)
GPL_WORDS = re.compile(r"general public licen|\bgpl\b|\blgpl\b|copyleft", re.I)
FAMILIES = [
    ("IJG", re.compile(r"independent jpeg group", re.I)),
    ("BSD", re.compile(r"redistribution and use in source and binary forms", re.I)),
    ("BSL-1.0", re.compile(r"boost software license", re.I)),
    ("MIT", re.compile(r"permission is hereby granted, free of charge, to any person obtaining a copy", re.I)),
    ("ISC", re.compile(r"permission to use, copy, modify, and(?:/or)? distribute this software for any "
                       r"purpose with or without fee is hereby granted", re.I)),
    ("zlib", re.compile(r"this software is provided ['\"]as-is['\"], without any express or implied warranty", re.I)),
    # Blocks that only name the license of the code they derive from, without its text.
    ("BSD origin named", re.compile(r"bsd[- ]licen|\(new\) bsd licen", re.I)),
    ("public domain origin named", re.compile(r"public domain", re.I)),
]
IJG_SENTENCE = "This software is based in part on the work of the Independent JPEG Group."


def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="replace")


def comment_blocks(text, ext):
    """Comment blocks of a file as lists of raw lines (comment markers kept, for verbatim copies)."""
    blocks = []
    if ext == ".asm":
        cur = []
        for line in text.splitlines():
            if line.lstrip().startswith(";"):
                cur.append(line.rstrip())
            elif cur:
                blocks.append(cur)
                cur = []
        if cur:
            blocks.append(cur)
        return blocks
    for m in re.finditer(r"/\*.*?\*/", text, re.S):
        blocks.append([l.rstrip() for l in m.group(0).splitlines()])
    cur = []
    for line in text.splitlines():
        if line.lstrip().startswith("//"):
            cur.append(line.rstrip())
        elif cur:
            blocks.append(cur)
            cur = []
    if cur:
        blocks.append(cur)
    return blocks


def plain(block):
    """Block text without comment markers, lower case, whitespace collapsed."""
    out = []
    for line in block:
        s = line.strip()
        s = re.sub(r"^(?:/\*+|\*+/|\*+|//+|;+\**)", "", s)
        s = re.sub(r"\*+/$", "", s)
        out.append(s.strip())
    return re.sub(r"\s+", " ", " ".join(out)).strip().lower()


def classify(block):
    """(kind, residual): kind is None (no license text), 'LGPL', a family name, or 'UNKNOWN'/'GPL'."""
    text = plain(block)
    lgpl = False
    for part in LGPL_PARTS:
        text, n = re.subn(part, " ", text)
        lgpl = lgpl or n > 0
    # Copyright lines alone are not license text.
    residual = re.sub(r"\s+", " ", text).strip()
    if not LICENSE_WORDS.search(residual):
        return ("LGPL" if lgpl else None), residual
    if GPL_WORDS.search(residual):
        return "GPL", residual
    for name, rx in FAMILIES:
        if rx.search(residual):
            return name, residual
    return "UNKNOWN", residual


def parse_dep(path):
    text = read_text(path).replace("\\\n", " ")
    files = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        files.extend(line.split(":", 1)[1].split())
    return files


# Include lines are followed only from these files (and from sources without a dependency file). C
# headers are not scanned: the dependency files list what the preprocessor really included.
SCAN_EXTS = (".asm", ".cu", ".cuh", ".rc")
INCLUDE_RX = re.compile(r'^\s*(?:#\s*include|%\s*include)\s+"([^"]+)"', re.M)


def includes(root, rel):
    found = []
    try:
        text = read_text(os.path.join(root, rel))
    except OSError:
        return found
    for inc in INCLUDE_RX.findall(text):
        for cand in (os.path.join(os.path.dirname(rel), inc), inc, os.path.join("compat", inc)):
            cand = os.path.normpath(cand)
            if os.path.isfile(os.path.join(root, cand)):
                found.append(cand)
                break
    return found


def main():
    root, out_path, log_path, title = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    root = os.path.abspath(root)
    objects = []
    for base, dirs, files in os.walk(root):
        dirs.sort()
        for f in sorted(files):
            if f.endswith(".o"):
                rel = os.path.relpath(os.path.join(base, f), root).replace(os.sep, "/")
                if not rel.startswith(HOST_DIRS):
                    objects.append(rel)
    if not objects:
        print("no objects found under " + root, file=sys.stderr)
        return 1

    files = {}  # file -> set of objects that use it
    unmapped = []
    for obj in objects:
        stem = obj[:-2]
        deps = []
        if os.path.isfile(os.path.join(root, stem + ".d")):
            deps = [d for d in parse_dep(os.path.join(root, stem + ".d")) if not os.path.isabs(d)]
        src = None
        # vf_x.ptx.o embeds the PTX that clang compiled from vf_x.cu.
        if stem.endswith(".ptx") or stem.endswith(".ptx.gz"):
            cu = re.sub(r"\.ptx(?:\.gz)?$", ".cu", stem)
            if os.path.isfile(os.path.join(root, cu)):
                src = cu
        for ext in SOURCE_EXTS:
            if src is None and os.path.isfile(os.path.join(root, stem + ext)):
                src = stem + ext
        if src is None and not deps:
            unmapped.append(obj)
            continue
        todo = ([src] if src else []) + deps
        seen = set()
        while todo:
            f = os.path.normpath(todo.pop()).replace(os.sep, "/")
            if f in seen or f.startswith("../") or not os.path.isfile(os.path.join(root, f)):
                continue
            seen.add(f)
            if f.endswith(SCAN_EXTS) or (f == src and not deps):
                todo.extend(includes(root, f))
        for f in seen:
            files.setdefault(f, set()).add(obj)
    if unmapped:
        print("objects without a source file: " + " ".join(unmapped), file=sys.stderr)
        return 1

    notices = []  # (file, kind, block)
    log = []
    bad = []
    for f in sorted(files):
        ext = os.path.splitext(f)[1]
        kinds = []
        for block in comment_blocks(read_text(os.path.join(root, f)), ext):
            kind, residual = classify(block)
            if kind is None:
                continue
            kinds.append(kind)
            if kind in ("UNKNOWN", "GPL"):
                bad.append((f, kind, residual[:400]))
            elif kind != "LGPL":
                notices.append((f, kind, block))
        log.append("%-60s %-18s %d objects" % (f, ",".join(sorted(set(kinds))) or "-", len(files[f])))

    with open(log_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("%d objects, %d source and header files\n" % (len(objects), len(files)))
        fh.write("\n".join(log) + "\n")
    if bad:
        for f, kind, residual in bad:
            print("unrecognized license text (%s) in %s: %s" % (kind, f, residual), file=sys.stderr)
        return 1

    fams = sorted({k for _, k, _ in notices})
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(title + "\n\n")
        fh.write(
            "FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later\n"
            "(LICENSE.txt, FFmpeg-LICENSE.md). Some source files compiled into these binaries carry other\n"
            "licenses as well. Their notices follow, copied verbatim from the unmodified FFmpeg source.\n"
            "The list is generated by scripts/notices.py from the %d compiled objects of this build\n"
            "and the %d source and header files they use.\n\n" % (len(objects), len(files))
        )
        if "IJG" in fams:
            fh.write(IJG_SENTENCE + "\n\n")
        fh.write("Licenses: " + ", ".join(fams) + "\n")
        fh.write("Files: " + ", ".join(sorted({f for f, _, _ in notices})) + "\n")
        for f, kind, block in notices:
            fh.write("\n" + "=" * 100 + "\n")
            fh.write("%s (%s)\n" % (f, kind))
            fh.write("=" * 100 + "\n")
            fh.write("\n".join(block) + "\n")
    print("notices: %d blocks from %d files (%s); %d objects, %d files scanned"
          % (len(notices), len({f for f, _, _ in notices}), ", ".join(fams), len(objects), len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
