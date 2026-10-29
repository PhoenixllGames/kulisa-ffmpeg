"""Third party notices of the FFmpeg code that is compiled into this build.

usage: notices.py <ffmpeg-build-dir> <ffmpeg-release-tarball> <allow-list> <notices-out> <log-out> <title>

1. Inputs. Maps every compiled object (*.o) of the in-tree FFmpeg build back to its source file and to
   every file of the tree that went into it:
     - the compiler dependency file (.d) of the object;
     - the files forced into a compile by flags (-include in CPPFLAGS, CFLAGS and NVCCFLAGS of
       ffbuild/config.mak, and config.asm, which common.mak pre-includes into every x86 assembly file);
     - the include lines of assembly, CUDA and resource files, of sources without a dependency file and
       of every generator input below (followed transitively);
     - generated intermediates: every used file that is not in the FFmpeg release tarball must match a
       rule in GENERATED, and the inputs of that rule are scanned as well (for example vf_scale_cuda.ptx.c
       to vf_scale_cuda.cu plus the -include files of NVCCFLAGS, uops_macros.gen.asm to
       uops_macros.asm.h plus the -include files of CPPFLAGS). A generated file without a rule, or a
       rule input that does not exist, stops the build.
   Objects of host tools (ffbuild/) are not part of the shipped binaries and are skipped.
2. Comment blocks. Every comment block of every used file is read:
     - the standard FFmpeg LGPL 2.1 or later header is recognized and needs no notice (LICENSE.txt);
     - a block with GPL text stops the build;
     - any other block that contains license-like words (TRIGGER) must be listed in the allow list with
       its file, its reviewed family and the SHA-256 of its normalized text. Blocks of a license family
       are copied verbatim into the notices file; blocks of family "none" (API documentation that
       mentions the word license) are not. A block that is not listed, a listed block whose text
       changed, and a listed block whose text does not match the pattern of its family stop the build,
       so a new FFmpeg version re-confirms every block. Listed entries that the build no longer uses
       are reported in the log.
"""
import hashlib
import os
import re
import sys
import tarfile

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
# Words that make a block (after the LGPL parts are removed) need a reviewed allow-list entry. Broad on
# purpose: "licen" covers license, licence, licensed, licensing; the rest catches license text that
# does not use that word.
TRIGGER = re.compile(
    r"licen[cs]|governed by|wtfpl|unlicense|creative ?commons|\bcc[- ]?by\b|\bcc0\b|public domain|"
    r"copyleft|\bgpl\b|permission is hereby granted|redistribution and use|permission to use|"
    r"is free software|warrant(?:y|ies)|provided ['\"]?as[- ]is|all rights reserved|"
    r"\bpatent|copyright waiver|spdx|independent jpeg group|terms and conditions|terms of use|\beula\b|"
    r"proprietary|confidential|non-?commercial|trademark",
    re.I,
)
GPL_WORDS = re.compile(r"general public licen|\bgpl\b|\blgpl\b|copyleft", re.I)
# Pattern each reviewed family must match, as a check of the allow list.
FAMILIES = {
    "IJG": re.compile(r"independent jpeg group", re.I),
    "BSD": re.compile(r"redistribution and use in source and binary forms", re.I),
    "BSL-1.0": re.compile(r"boost software license", re.I),
    "MIT": re.compile(r"permission is hereby granted, free of charge, to any person obtaining a copy", re.I),
    "ISC": re.compile(r"permission to use, copy, modify, and(?:/or)? distribute this software for any "
                      r"purpose with or without fee is hereby granted", re.I),
    "zlib": re.compile(r"this software is provided ['\"]as-is['\"], without any express or implied warranty", re.I),
    # Blocks that only name the license of the code they derive from, without its text.
    "BSD-origin-named": re.compile(r"bsd[- ]licen|\(new\) bsd licen", re.I),
    "public-domain-origin-named": re.compile(r"public domain", re.I),
    # Not license text: documentation that mentions a license (for example the avcodec_license() API).
    "none": re.compile(r""),
}
IJG_SENTENCE = "This software is based in part on the work of the Independent JPEG Group."

# Generated intermediates (in-tree build), as (regex on the path, inputs). An input "\\1" refers to the
# regex group; "@CPPFLAGS" and the like stand for the -include files of that config.mak variable.
GENERATED = [
    # Written by configure from the configure line.
    (r"config\.h|config\.asm|config_components\.h|config_components\.asm|libavutil/avconfig\.h|"
     r"lib\w+/\w+_list\.c", ["configure"]),
    # Written by ffbuild/version.sh from the RELEASE file of the release tarball.
    (r"libavutil/ffversion\.h", ["ffbuild/version.sh", "RELEASE"]),
    # common.mak: "%.ptx: %.cu $(SRC_PATH)/compat/cuda/cuda_runtime.h", compiled with $(NVCCFLAGS), and
    # bin2c turns the PTX (or its gzip) into a C array.
    (r"(.+)\.ptx(?:\.gz)?(?:\.c)?", ["\\1.cu", "@NVCCFLAGS"]),
    # libswscale/x86/Makefile: "$(HOSTCC) $(HOSTCC_E) $(CPPFLAGS) $<" of x86/uops_macros.asm.h.
    (r"(.+)\.gen\.asm", ["\\1.asm.h", "@CPPFLAGS"]),
    # common.mak: %.html.c and %.css.c from the .html and .css files (minified, gzipped, bin2c).
    (r"(.+\.(?:html|css))(?:\.min)?(?:\.gz)?\.c", ["\\1"]),
]
# Forced includes of each compile, by the extension of the source file.
FORCED_BY_EXT = {
    ".c": ["@CPPFLAGS", "@CFLAGS"],
    ".cpp": ["@CPPFLAGS", "@CXXFLAGS"],
    ".S": ["@CPPFLAGS", "@ASFLAGS"],
    ".cu": ["@NVCCFLAGS"],
    # common.mak: X86ASMFLAGS += ... -Pconfig.asm
    ".asm": ["config.asm"],
}


def read_text(path):
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="replace")


def comment_blocks(text, ext):
    """Comment blocks of a file as lists of raw lines (comment markers kept, for verbatim copies)."""
    def line_blocks(prefix):
        blocks, cur = [], []
        for line in text.splitlines():
            if line.lstrip().startswith(prefix):
                cur.append(line.rstrip())
            elif cur:
                blocks.append(cur)
                cur = []
        if cur:
            blocks.append(cur)
        return blocks

    if ext == ".asm":
        return line_blocks(";")
    if ext in ("", ".sh", ".mak"):
        return line_blocks("#")
    blocks = []
    if ext == ".html":
        for m in re.finditer(r"<!--.*?-->", text, re.S):
            blocks.append([l.rstrip() for l in m.group(0).splitlines()])
    for m in re.finditer(r"/\*.*?\*/", text, re.S):
        blocks.append([l.rstrip() for l in m.group(0).splitlines()])
    return blocks + line_blocks("//")


def plain(block):
    """Block text without comment markers, lower case, whitespace collapsed."""
    out = []
    for line in block:
        s = line.strip()
        s = re.sub(r"^(?:<!--|/\*+|\*+/|\*+|//+|;+\**|#+)", "", s)
        s = re.sub(r"(?:\*+/|-->)$", "", s)
        out.append(s.strip())
    return re.sub(r"\s+", " ", " ".join(out)).strip().lower()


def block_hash(block):
    return hashlib.sha256(plain(block).encode("utf-8")).hexdigest()


def classify(block):
    """(kind, residual): kind is None (no license-like words), 'LGPL', 'GPL' or 'REVIEW'."""
    text = plain(block)
    lgpl = False
    for part in LGPL_PARTS:
        text, n = re.subn(part, " ", text)
        lgpl = lgpl or n > 0
    residual = re.sub(r"\s+", " ", text).strip()
    if GPL_WORDS.search(residual):
        return "GPL", residual
    if not TRIGGER.search(residual):
        return ("LGPL" if lgpl else None), residual
    return "REVIEW", residual


def load_allow(path):
    """{(file, sha256): family} from lines '<sha256> <family> <file>'; '#' starts a comment."""
    allow = {}
    for n, line in enumerate(read_text(path).splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]) or parts[1] not in FAMILIES:
            raise SystemExit("%s:%d: bad allow-list line: %s" % (path, n, line))
        allow[(parts[2], parts[0])] = parts[1]
    return allow


def parse_dep(path):
    text = read_text(path).replace("\\\n", " ")
    files = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        files.extend(line.split(":", 1)[1].split())
    return files


INCLUDE_RX = re.compile(r'^\s*(?:#\s*include|%\s*include)\s+"([^"]+)"', re.M)
# Include lines are followed from these files, from sources without a dependency file and from every
# generator input. Other C headers are not scanned: the dependency files list what the preprocessor
# really included.
SCAN_EXTS = (".asm", ".cu", ".cuh", ".rc")


def includes(root, rel):
    found = []
    try:
        text = read_text(os.path.join(root, rel))
    except OSError:
        return found
    for inc in INCLUDE_RX.findall(text):
        for cand in (os.path.join(os.path.dirname(rel), inc), inc, os.path.join("compat", inc)):
            cand = os.path.normpath(cand).replace(os.sep, "/")
            if os.path.isfile(os.path.join(root, cand)):
                found.append(cand)
                break
    return found


def config_vars(root):
    """Variables of ffbuild/config.mak (VAR=value lines)."""
    out = {}
    path = os.path.join(root, "ffbuild", "config.mak")
    for line in read_text(path).splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:?=\s*(.*)$", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def forced_includes(root, value):
    """Files named by -include/--include in a flag string, relative to the build tree."""
    toks = value.split()
    found = []
    for i, t in enumerate(toks):
        path = None
        if t in ("-include", "--include") and i + 1 < len(toks):
            path = toks[i + 1]
        elif t.startswith("--include="):
            path = t.split("=", 1)[1]
        if path is None:
            continue
        if os.path.isabs(path):
            path = os.path.relpath(path, root)
        path = os.path.normpath(path).replace(os.sep, "/")
        if path.startswith("src/"):
            path = path[4:]
        found.append(path)
    return found


def main():
    if len(sys.argv) != 7:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    root, tarball, allow_path, out_path, log_path, title = sys.argv[1:7]
    root = os.path.abspath(root)
    allow = load_allow(allow_path)

    with tarfile.open(tarball, "r:xz") as tf:
        released = set()
        for name in tf.getnames():
            parts = name.split("/", 1)
            if len(parts) == 2 and parts[1]:
                released.add(parts[1].rstrip("/"))

    cfg = config_vars(root)
    flag_files = {}
    for var in ("CPPFLAGS", "CFLAGS", "CXXFLAGS", "ASFLAGS", "NVCCFLAGS"):
        flag_files["@" + var] = forced_includes(root, cfg.get(var, ""))

    def expand(names, match=None):
        out = []
        for n in names:
            if n.startswith("@"):
                out.extend(flag_files[n])
            else:
                out.append(match.expand(n) if match else n)
        return out

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
    generated = {}  # generated file -> its inputs
    unmapped, errors = [], []
    for obj in objects:
        stem = obj[:-2]
        deps = []
        if os.path.isfile(os.path.join(root, stem + ".d")):
            deps = [d for d in parse_dep(os.path.join(root, stem + ".d")) if not os.path.isabs(d)]
        src = None
        for ext in SOURCE_EXTS:
            if src is None and os.path.isfile(os.path.join(root, stem + ext)):
                src = stem + ext
        if src is None and not deps:
            unmapped.append(obj)
            continue
        # (file, follow its include lines)
        todo = [(d, False) for d in deps]
        if src:
            todo.append((src, not deps))
            todo.extend((f, True) for f in expand(FORCED_BY_EXT.get(os.path.splitext(src)[1], [])))
        seen = set()
        followed = set()
        while todo:
            f, follow = todo.pop()
            f = os.path.normpath(f).replace(os.sep, "/")
            if f.startswith("../") or os.path.isabs(f):
                continue
            if f in followed or (f in seen and not follow):
                continue
            exists = os.path.isfile(os.path.join(root, f))
            if f not in released:
                rule = next(((rx, ins) for rx, ins in GENERATED if re.fullmatch(rx, f)), None)
                if rule is None:
                    if exists:
                        errors.append("generated file without a rule in GENERATED: %s (%s)" % (f, obj))
                    continue
                inputs = expand(rule[1], re.fullmatch(rule[0], f))
                for i in inputs:
                    if os.path.normpath(i).replace(os.sep, "/") not in released and not any(
                            re.fullmatch(rx, i) for rx, _ in GENERATED):
                        errors.append("input %s of generated %s is not in the release tarball" % (i, f))
                generated[f] = inputs
                todo.extend((i, True) for i in inputs)
                if not exists:  # an intermediate that make deleted (the .ptx of a .ptx.c)
                    followed.add(f)
                    continue
            elif not exists:
                errors.append("missing source file %s (%s)" % (f, obj))
                continue
            seen.add(f)
            # configure and version.sh are scripts: their include lines are C test code, not inputs.
            if (follow or f.endswith(SCAN_EXTS)) and os.path.splitext(f)[1] not in ("", ".sh"):
                followed.add(f)
                todo.extend((i, True) for i in includes(root, f))
        for f in seen:
            files.setdefault(f, set()).add(obj)
    if unmapped:
        errors.append("objects without a source file: " + " ".join(unmapped))
    if errors:
        for e in sorted(set(errors)):
            print(e, file=sys.stderr)
        return 1

    notices = []  # (file, family, block)
    log = []
    bad = []
    used_allow = set()
    for f in sorted(files):
        ext = os.path.splitext(f)[1]
        kinds = []
        for block in comment_blocks(read_text(os.path.join(root, f)), ext):
            kind, residual = classify(block)
            if kind is None:
                continue
            if kind == "REVIEW":
                key = (f, block_hash(block))
                fam = allow.get(key)
                if fam is None:
                    bad.append("license-like text not in the allow list: %s %s %s\n    %s"
                               % (key[1], "<family>", f, residual[:400]))
                    continue
                if not FAMILIES[fam].search(residual):
                    bad.append("allow-list family %s does not match the text of %s %s" % (fam, key[1], f))
                    continue
                used_allow.add(key)
                kind = fam
                if fam != "none":
                    notices.append((f, fam, block))
            elif kind == "GPL":
                bad.append("GPL text in %s: %s" % (f, residual[:400]))
                continue
            kinds.append(kind)
        gen = (" <- " + ", ".join(generated[f])) if f in generated else ""
        log.append("%-60s %-26s %d objects%s" % (f, ",".join(sorted(set(kinds))) or "-", len(files[f]), gen))
    unused = sorted(set(allow) - used_allow)

    with open(log_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("%d objects, %d source and header files (%d generated)\n"
                 % (len(objects), len(files), len([f for f in files if f in generated])))
        for var in sorted(flag_files):
            fh.write("forced includes %s: %s\n" % (var, " ".join(flag_files[var]) or "-"))
        for key in unused:
            fh.write("allow-list entry not used by this build: %s %s %s\n" % (key[1], allow[key], key[0]))
        fh.write("\n".join(log) + "\n")
    if bad:
        for b in bad:
            print(b, file=sys.stderr)
        return 1

    fams = sorted({k for _, k, _ in notices})
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(title + "\n\n")
        fh.write(
            "FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later\n"
            "(LICENSE.txt, FFmpeg-LICENSE.md). Some source files compiled into these binaries carry other\n"
            "licenses as well. Their notices follow, copied verbatim from the unmodified FFmpeg source.\n"
            "The list is generated by scripts/notices.py from the %d compiled objects of this build\n"
            "and the %d source, header and generator input files they use.\n\n" % (len(objects), len(files))
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
    print("notices: %d blocks from %d files (%s); %d objects, %d files scanned, %d unused allow-list entries"
          % (len(notices), len({f for f, _, _ in notices}), ", ".join(fams), len(objects), len(files),
             len(unused)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
