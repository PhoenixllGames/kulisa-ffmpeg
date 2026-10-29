"""Third party notices of everything that is compiled into the FFmpeg binaries of this build.

usage: notices.py --build-dir DIR --tarball FILE --allow FILE --origins DIR --versions FILE
                  --vpl-deps FILE --vpl-src DIR --gcc-copyright FILE --out-dir DIR --log FILE --title TEXT

Part A. FFmpeg code (the in-tree build, --build-dir).
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
3. Origins. A block of family BSD-origin-named or public-domain-origin-named only names the project it
   derives from, and a block of another family may name its origin as well (Boost, LLVM). The allow-list
   line names the origins (origin=a,b; required for the two origin families); the license text of each
   origin is the file origin-<name>.txt of --origins (fetched from the primary upstream source, with its
   source URL) and is appended to the notices, once per origin.

Part B. External headers and sources: everything the compiler read that is not FFmpeg's own tree.
   The dependency files of the FFmpeg objects (made with -MD, so system headers are listed too) and the
   ninja deps of the static libvpl build (--vpl-deps, from "ninja -t deps") give the file list. Every
   file is resolved (symlinks) and assigned to a project by its path: nv-codec-headers, AMF, libvpl,
   libstdc++ (the C++ headers of the toolchain), gcc (its other headers) or mingw-w64. A file of no
   project stops the build. The comment blocks are classified as above, with the allow list keyed by
   "<project>:<path>" or "<project>:*" (any file of the project; the hash still pins the text), and a
   standard header per project that needs no copy (GPL 3 with the GCC Runtime Library Exception for
   libstdc++ and gcc, the mingw-w64 runtime header). Per project, one notices file in --out-dir groups
   the distinct blocks (each once, with the files that carry it) and the copyright lines of the
   standard headers.
"""
import argparse
import glob
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
# Standard header of the GCC runtime code (libstdc++ headers, GCC headers): GPL 3 or later with the GCC
# Runtime Library Exception 3.1. Its text is in the notices of the libstdc++ project.
GCC_WHO = r"(?:this library|gcc|this file|this program|libgcc|libstdc\+\+)"
GCC_PARTS = [
    r"this file is part of (?:the gnu iso c\+\+ library|gcc|libgcc|libstdc\+\+)[.,]?",
    GCC_WHO + r" is free software;? you can redistribute (?:it|them) and/or modify (?:it|them) under the "
    r"terms of the gnu general public license as published by the free software foundation;? either "
    r"version 3,? or \(at your option\) any later version\.",
    GCC_WHO + r" is distributed in the hope that it will be useful, but without any warranty;? without "
    r"even the implied warranty of merchantability or fitness for a particular purpose\.? see the gnu "
    r"general public license for more details\.",
    r"under section 7 of gpl version 3, you are granted additional permissions described in the gcc "
    r"runtime library exception, version 3\.1, as published by the(?:, \d{4})? free software foundation\.",
    r"you should have received a copy of the gnu general public license and a copy of the gcc runtime "
    r"library exception along with this program;? see the files copying3 and copying\.runtime "
    r"respectively\.? if not, see <http://www\.gnu\.org/licenses/>\.",
]
# Standard headers of the mingw-w64 headers: the mingw-w64 runtime header, the public domain sentence of
# the mingw runtime, and the LGPL 2.1 or later header of the headers that come from the Wine project.
MINGW_PARTS = [
    r"this file is part of the (?:[\w-]+ ){0,3}(?:package|project)\.?",
    r"no warranty is given;? refer to the file disclaimer(?:\.pd)? within (?:this|the) package\.?",
    r"this file has no copyright assigned and is placed in the public domain\.?",
] + LGPL_PARTS
STD_PARTS = {"FFmpeg": LGPL_PARTS, "libstdc++": GCC_PARTS, "gcc": GCC_PARTS, "mingw-w64": MINGW_PARTS}

# Words that make a block (after the standard parts are removed) need a reviewed allow-list entry.
# Broad on purpose: "licen" covers license, licence, licensed, licensing; the rest catches license text
# that does not use that word.
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
    "SPDX-MIT": re.compile(r"spdx-license-identifier:\s*mit\b", re.I),
    # Permission notices of the C++ standard library headers (libstdc++): Hewlett-Packard, Silicon Graphics.
    "HP": re.compile(r"hewlett-packard", re.I),
    "SGI": re.compile(r"silicon graphics", re.I),
    "HP+SGI": re.compile(r"(?=.*hewlett-packard)(?=.*silicon graphics)", re.I),
    "Apache-2.0-LLVM": re.compile(r"apache license v2\.0 with llvm exceptions?", re.I),
    "public-domain": re.compile(r"public domain", re.I),
    # GPL header with a special exception for the object code that includes it (stdarg.h of mingw-w64).
    "GPL-exception": re.compile(r"special exception|general public license", re.I),
    # Not license text: documentation that mentions a license (for example the avcodec_license() API).
    "none": re.compile(r""),
}
ORIGIN_FAMILIES = ("BSD-origin-named", "public-domain-origin-named")
# The only family allowed for a block with GPL text; any other GPL text stops the build.
GPL_FAMILY = "GPL-exception"
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

# External projects: the file that carries their notices, a title line and the license statement.
SYSROOT = "/usr/x86_64-w64-mingw32"
MINGW_INCLUDE = "/usr/share/mingw-w64/include"
GCC_INCLUDE_GLOB = "/usr/lib/gcc/x86_64-w64-mingw32/*/include"
PROJECTS = {
    "nv-codec-headers": ("nv-codec-headers-LICENSE.txt",
                         "nv-codec-headers {NV_CODEC_HEADERS_VERSION}, https://github.com/FFmpeg/nv-codec-headers",
                         "MIT license. Headers only; the NVIDIA runtime libraries are loaded from the GPU driver."),
    "AMF": ("AMF-LICENSE.txt",
            "AMD Advanced Media Framework (AMF) headers {AMF_VERSION}, https://github.com/GPUOpen-LibrariesAndSDKs/AMF",
            "MIT license. Headers only; the AMF runtime is loaded from the GPU driver."),
    "libvpl": ("libvpl-LICENSE.txt",
               "Intel Video Processing Library (libvpl) {LIBVPL_VERSION}, https://github.com/intel/libvpl",
               "Linked statically into the FFmpeg libraries (dispatcher only)."),
    "libstdc++": ("libstdc++-notices.txt",
                  "libstdc++ and GCC headers of the mingw-w64 toolchain (GCC {GCC_VERSION}), https://gcc.gnu.org/",
                  "The static libvpl dispatcher is C++ and is compiled against the libstdc++ headers; libgcc and "
                  "libstdc++ are linked statically."),
    "mingw-w64": ("mingw-w64-headers-notices.txt",
                  "mingw-w64 headers, https://www.mingw-w64.org/",
                  "The Windows and C runtime headers that the FFmpeg and libvpl objects include. The copyright "
                  "file of the statically linked runtime is mingw-w64-runtime.txt."),
}
# gcc headers go into the file of libstdc++ (one GCC section).
PROJECT_FILE = {"nv-codec-headers": "nv-codec-headers", "AMF": "AMF", "libvpl": "libvpl", "libstdc++": "libstdc++",
                "gcc": "libstdc++", "mingw-w64": "mingw-w64"}
PROJECT_TITLE = {"libstdc++": "libstdc++ headers", "gcc": "GCC compiler headers"}
RLE_START = "GCC RUNTIME LIBRARY EXCEPTION"
RLE_END = "requirements of the license of GCC."


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


def classify(block, parts):
    """(kind, residual, matched): kind is None (no license-like words), 'STANDARD' (a standard header of the
    project, see STD_PARTS), 'GPL' or 'REVIEW'."""
    text = plain(block)
    matched = []
    for part in parts:
        text = re.sub(part, lambda m: matched.append(m.group(0)) or " ", text)
    residual = re.sub(r"\s+", " ", text).strip()
    if GPL_WORDS.search(residual):
        return "GPL", residual, matched
    if not TRIGGER.search(residual):
        return ("STANDARD" if matched else None), residual, matched
    return "REVIEW", residual, matched


def load_allow(path):
    """{(file, sha256): (family, origins)} from lines '<sha256> <family> <file> [origin=a,b]'.
    '#' starts a comment. File is a path of the FFmpeg tree, or '<project>:<path>' / '<project>:*'."""
    allow = {}
    for n, line in enumerate(read_text(path).splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        origins = ()
        if len(parts) == 4 and parts[3].startswith("origin="):
            origins = tuple(parts[3][len("origin="):].split(","))
            parts = parts[:3]
        if len(parts) != 3 or not re.fullmatch(r"[0-9a-f]{64}", parts[0]) or parts[1] not in FAMILIES:
            raise SystemExit("%s:%d: bad allow-list line: %s" % (path, n, line))
        if (parts[1] in ORIGIN_FAMILIES and not origins) or (origins and parts[1] == "none"):
            raise SystemExit("%s:%d: origin= is required for the families %s and not allowed for none: %s"
                             % (path, n, ", ".join(ORIGIN_FAMILIES), line))
        allow[(parts[2], parts[0])] = (parts[1], origins)
    return allow


def parse_dep(path):
    text = read_text(path).replace("\\\n", " ")
    files = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        files.extend(line.split(":", 1)[1].split())
    return files


def parse_ninja_deps(path):
    """{object: [dependency files]} from the output of 'ninja -t deps'."""
    deps, cur = {}, None
    for line in read_text(path).splitlines():
        if not line.strip():
            continue
        if line.startswith(" "):
            if cur is None:
                raise SystemExit("%s: dependency line before an object: %s" % (path, line))
            deps[cur].append(line.strip())
        else:
            m = re.match(r"^(.+?): #deps \d+", line)
            if not m:
                raise SystemExit("%s: unexpected line: %s" % (path, line))
            cur = m.group(1)
            deps[cur] = []
    return deps


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


def load_env(path):
    """KEY=VALUE lines of versions.env."""
    out = {}
    for line in read_text(path).splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2)
    return out


def strip_markers(block):
    """Lines of a block without comment markers (for the project notices files)."""
    out = []
    for line in block:
        s = line.rstrip()
        s = re.sub(r"^\s*(?:<!--|/\*+|\*+/|\*(?!\S)|\*\s?|//+ ?|;+ ?|# ?)", "", s)
        s = re.sub(r"\s*(?:\*+/|-->)$", "", s)
        out.append(s.rstrip())
    while out and not out[0].strip():
        out.pop(0)
    while out and not out[-1].strip():
        out.pop()
    return out


COPYRIGHT_RX = re.compile(r"copyright|\(c\)\s*\d{4}", re.I)


class External:
    """Files of the external projects, their blocks and the project notices."""

    def __init__(self, vpl_src, gcc_include):
        self.vpl_src = os.path.realpath(vpl_src)
        sysroot = os.path.realpath(SYSROOT)
        inc = sysroot + "/include/"
        self.roots = [
            (inc + "ffnvcodec/", "nv-codec-headers", inc),
            (inc + "AMF/", "AMF", inc),
            (inc + "vpl/", "libvpl", inc),
            (self.vpl_src + "/", "libvpl", self.vpl_src + "/"),
            (gcc_include + "/c++/", "libstdc++", gcc_include + "/c++/"),
            (gcc_include + "/", "gcc", gcc_include + "/"),
            (os.path.realpath(MINGW_INCLUDE) + "/", "mingw-w64", os.path.realpath(MINGW_INCLUDE) + "/"),
            (inc, "mingw-w64", inc),
        ]
        self.files = {}  # (project, relpath) -> (real path, set of users)

    def add(self, path, user):
        """Registers an absolute path; returns False when no project owns it."""
        real = os.path.realpath(path)
        for prefix, proj, base in self.roots:
            if real.startswith(prefix):
                key = (proj, real[len(base):])
                self.files.setdefault(key, (real, set()))[1].add(user)
                return True
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    for name in ("build-dir", "tarball", "allow", "origins", "versions", "vpl-deps", "vpl-src",
                 "gcc-copyright", "out-dir", "log", "title"):
        ap.add_argument("--" + name, required=True)
    args = ap.parse_args()
    root = os.path.abspath(args.build_dir)
    allow = load_allow(args.allow)
    versions = load_env(args.versions)
    gcc_dirs = sorted(glob.glob(GCC_INCLUDE_GLOB))
    if len(gcc_dirs) != 1:
        raise SystemExit("expected one GCC include directory, found: %s" % gcc_dirs)
    gcc_include = os.path.realpath(gcc_dirs[0])
    versions["GCC_VERSION"] = gcc_include.split("/")[-2]
    ext = External(args.vpl_src, gcc_include)

    with tarfile.open(args.tarball, "r:xz") as tf:
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
            for d in parse_dep(os.path.join(root, stem + ".d")):
                if os.path.isabs(d):
                    if not ext.add(d, obj):
                        errors.append("external file of no known project: %s (%s)" % (d, obj))
                else:
                    deps.append(d)
        src = None
        for e in SOURCE_EXTS:
            if src is None and os.path.isfile(os.path.join(root, stem + e)):
                src = stem + e
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

    # Part B inputs: the objects of the static libvpl build.
    vpl_deps = parse_ninja_deps(args.vpl_deps)
    if not vpl_deps:
        errors.append("no objects in " + args.vpl_deps)
    for obj, deps in sorted(vpl_deps.items()):
        if not deps:
            errors.append("libvpl object without dependencies: " + obj)
        for d in deps:
            if not os.path.isabs(d):
                d = os.path.join(args.vpl_src, d)
            if not ext.add(d, "libvpl:" + obj):
                errors.append("external file of no known project: %s (libvpl:%s)" % (d, obj))
    for key, (real, _users) in sorted(ext.files.items()):
        if not os.path.isfile(real):
            errors.append("external file does not exist: %s:%s (%s)" % (key[0], key[1], real))
    if errors:
        for e in sorted(set(errors)):
            print(e, file=sys.stderr)
        return 1

    bad = []
    used_allow = set()

    def lookup(file_id, project_wild, h):
        """Allow-list entry of a block: the file's own entry, or '<project>:*' for external files."""
        for key in ((file_id, h), (project_wild, h)):
            if key in allow:
                return key
        return None

    # ---- Part A: FFmpeg files
    notices = []  # (file, family, block, origins)
    log = []
    for f in sorted(files):
        fext = os.path.splitext(f)[1]
        kinds = []
        for block in comment_blocks(read_text(os.path.join(root, f)), fext):
            kind, residual, _matched = classify(block, STD_PARTS["FFmpeg"])
            if kind is None:
                continue
            if kind == "STANDARD":
                kind = "LGPL"
            else:
                h = block_hash(block)
                key = lookup(f, None, h)
                if key is None:
                    bad.append("%s text not in the allow list: %s <family> %s\n    %s"
                               % ("GPL" if kind == "GPL" else "license-like", h, f, residual[:3000]))
                    continue
                fam, origins = allow[key]
                if kind == "GPL" and fam != GPL_FAMILY:
                    bad.append("GPL text in %s can only be listed as %s: %s" % (f, GPL_FAMILY, h))
                    continue
                if not FAMILIES[fam].search(plain(block)):
                    bad.append("allow-list family %s does not match the text of %s %s" % (fam, h, f))
                    continue
                used_allow.add(key)
                kind = fam
                if fam != "none":
                    notices.append((f, fam, block, origins))
            kinds.append(kind)
        gen = (" <- " + ", ".join(generated[f])) if f in generated else ""
        log.append("%-60s %-26s %d objects%s" % (f, ",".join(sorted(set(kinds))) or "-", len(files[f]), gen))

    # Origin texts (third-party/origin-<name>.txt), loaded when a block names them.
    origin_texts = {}

    def origin(name):
        if name not in origin_texts:
            path = os.path.join(args.origins, "origin-%s.txt" % name)
            if not os.path.isfile(path):
                bad.append("origin text missing: %s (named by an allow-list line)" % path)
                origin_texts[name] = ""
            else:
                origin_texts[name] = read_text(path).rstrip("\n")
        return origin_texts[name]

    origin_files = {}
    for f, _fam, _block, origins in notices:
        for o in origins:
            origin(o)
            origin_files.setdefault(o, []).append(f)

    # ---- Part B: external files
    # project -> {"std": {text key: raw lines}, "copyright": set, "blocks": {text key: [family, lines, files]},
    #             "files": [relpaths]}
    proj = {}
    ext_log = []
    reported = set()
    for (p, rel) in sorted(ext.files):
        real, users = ext.files[(p, rel)]
        fid = "%s:%s" % (p, rel)
        data = proj.setdefault(p, {"std": {}, "copyright": set(), "blocks": {}, "files": []})
        data["files"].append(rel)
        parts = STD_PARTS.get(p, [])
        kinds = []
        for block in comment_blocks(read_text(real), ".h"):
            kind, residual, matched = classify(block, parts)
            if kind is None:
                continue
            if kind == "STANDARD":
                lines = strip_markers(block)
                cl = [l.strip() for l in lines if COPYRIGHT_RX.search(l)]
                body = [l for l in lines if not COPYRIGHT_RX.search(l)]
                data["copyright"].update(cl)
                # One entry per set of standard sentences; the shortest block that carries them is shown.
                skey = " | ".join(matched)
                if skey not in data["std"] or len(body) < len(data["std"][skey]):
                    data["std"][skey] = body
                kinds.append("standard")
                continue
            h = block_hash(block)
            key = lookup(fid, "%s:*" % p, h)
            if key is None:
                if (p, h) not in reported:
                    reported.add((p, h))
                    bad.append("%s text not in the allow list: %s <family> %s:* (first seen in %s)\n    %s"
                               % ("GPL" if kind == "GPL" else "license-like", h, p, rel, residual[:3000]))
                continue
            fam, origins = allow[key]
            if kind == "GPL" and fam != GPL_FAMILY:
                bad.append("GPL text in %s can only be listed as %s: %s" % (fid, GPL_FAMILY, h))
                continue
            if not FAMILIES[fam].search(plain(block)):
                bad.append("allow-list family %s does not match the text of %s %s" % (fam, h, fid))
                continue
            used_allow.add(key)
            kinds.append(fam)
            if fam != "none":
                entry = data["blocks"].setdefault(h, [fam, strip_markers(block), [], origins])
                entry[2].append(rel)
                for o in origins:
                    origin(o)
        ext_log.append("%-70s %-12s %-26s %d users" % (rel, p, ",".join(sorted(set(kinds))) or "-", len(users)))
    unused = sorted(k for k in set(allow) - used_allow)
    unused_origins = sorted(
        os.path.basename(p)[len("origin-"):-len(".txt")] for p in glob.glob(os.path.join(args.origins, "origin-*.txt"))
        if os.path.basename(p)[len("origin-"):-len(".txt")] not in origin_texts)

    with open(args.log, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("%d objects, %d source and header files (%d generated)\n"
                 % (len(objects), len(files), len([f for f in files if f in generated])))
        fh.write("%d external files of %d projects, %d libvpl objects\n"
                 % (len(ext.files), len(proj), len(vpl_deps)))
        for var in sorted(flag_files):
            fh.write("forced includes %s: %s\n" % (var, " ".join(flag_files[var]) or "-"))
        for key in unused:
            fh.write("allow-list entry not used by this build: %s %s %s\n" % (key[1], allow[key][0], key[0]))
        for o in unused_origins:
            fh.write("origin text not used by this build: origin-%s.txt\n" % o)
        fh.write("\n".join(log) + "\n")
        fh.write("\nexternal files\n")
        fh.write("\n".join(ext_log) + "\n")
    if bad:
        for b in bad:
            print(b, file=sys.stderr)
        return 1

    os.makedirs(args.out_dir, exist_ok=True)

    # ---- FFmpeg notices file
    fams = sorted({k for _, k, _, _ in notices})
    with open(os.path.join(args.out_dir, "FFmpeg-third-party-notices.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(args.title + "\n\n")
        fh.write(
            "FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later\n"
            "(LICENSE.txt, FFmpeg-LICENSE.md). Some source files compiled into these binaries carry other\n"
            "licenses as well. Their notices follow, copied verbatim from the unmodified FFmpeg source.\n"
            "The list is generated by scripts/notices.py from the %d compiled objects of this build\n"
            "and the %d source, header and generator input files they use.\n\n"
            "Blocks that name the project they derive from (for example the BSD-origin-named blocks) are\n"
            "followed by a pointer to the license text of that project, copied from its primary upstream\n"
            "source (section \"Origins\").\n"
            "Notices of the external headers that these objects include (nv-codec-headers, AMF, libvpl,\n"
            "libstdc++, GCC and mingw-w64) are in the other files of licenses/.\n\n"
            % (len(objects), len(files))
        )
        if "IJG" in fams:
            fh.write(IJG_SENTENCE + "\n\n")
        fh.write("Licenses: " + ", ".join(fams) + "\n")
        fh.write("Files: " + ", ".join(sorted({f for f, _, _, _ in notices})) + "\n")
        for f, kind, block, origins in notices:
            fh.write("\n" + "=" * 100 + "\n")
            fh.write("%s (%s)\n" % (f, kind))
            fh.write("=" * 100 + "\n")
            fh.write("\n".join(block) + "\n")
            if origins:
                fh.write("\nOrigin license text of this block: %s (see Origins)\n" % ", ".join(origins))
        if origin_files:
            fh.write("\n" + "=" * 100 + "\n")
            fh.write("Origins\n")
            fh.write("=" * 100 + "\n")
            fh.write("Licenses of the projects that blocks above name as the origin of FFmpeg code. Each text\n"
                     "is the license of the original project, copied from its primary upstream source.\n")
            for o in sorted(origin_files):
                fh.write("\n" + "-" * 100 + "\n")
                fh.write("%s (named by %s)\n" % (o, ", ".join(sorted(set(origin_files[o])))))
                fh.write("-" * 100 + "\n")
                fh.write(origin_texts[o] + "\n")

    # ---- project notices files
    rle = None
    gcc_text = read_text(args.gcc_copyright).splitlines()
    for i, line in enumerate(gcc_text):
        if line.strip() == RLE_START:
            for j in range(i, len(gcc_text)):
                if gcc_text[j].strip().endswith(RLE_END):
                    rle = gcc_text[i:j + 1]
                    break
            break
    if rle is None:
        print("GCC Runtime Library Exception text not found in " + args.gcc_copyright, file=sys.stderr)
        return 1

    summary = []
    by_file = {}
    for p in sorted(proj):
        by_file.setdefault(PROJECT_FILE[p], []).append(p)
    for pf in sorted(by_file):
        out_name, title, blurb = PROJECTS[pf]
        with open(os.path.join(args.out_dir, out_name), "w", encoding="utf-8", newline="\n") as fh:
            fh.write(title.format(**versions) + "\n" + blurb + "\n")
            if pf == "libvpl":
                fh.write("\nLICENSE of the libvpl source tree:\n\n")
                fh.write(read_text(os.path.join(args.vpl_src, "LICENSE")).rstrip("\n") + "\n")
            n_files = sum(len(proj[p]["files"]) for p in by_file[pf])
            fh.write("\nThis file is generated by scripts/notices.py from the %d header and source files of this "
                     "project that the compiler read\nwhen it built the shipped binaries (list: "
                     "logs/notices-sources.txt next to the release assets). Every distinct\nlicense block "
                     "appears once, followed by the files that carry it.\n" % n_files)
            for p in by_file[pf]:
                data = proj[p]
                if len(by_file[pf]) > 1 or p in PROJECT_TITLE:
                    fh.write("\n" + "#" * 100 + "\n# %s (%d files)\n" % (PROJECT_TITLE.get(p, p), len(data["files"]))
                             + "#" * 100 + "\n")
                if data["std"]:
                    if p in ("libstdc++", "gcc"):
                        fh.write("\nStandard header of these files: GNU General Public License version 3 or later "
                                 "with the GCC Runtime Library Exception 3.1\n(text below). Copyright lines of the "
                                 "files:\n")
                    else:
                        fh.write("\nStandard header of these files. Copyright lines of the files:\n")
                    for c in sorted(data["copyright"]):
                        fh.write("  " + c + "\n")
                    for t in sorted(data["std"]):
                        fh.write("\n" + "-" * 100 + "\nStandard header text\n" + "-" * 100 + "\n")
                        fh.write("\n".join(data["std"][t]) + "\n")
                for h in sorted(data["blocks"], key=lambda k: (data["blocks"][k][0], data["blocks"][k][2][0], k)):
                    fam, lines, rels, _origins = data["blocks"][h]
                    fh.write("\n" + "-" * 100 + "\n%s notice, carried by %d file%s: %s\n"
                             % (fam, len(set(rels)), "" if len(set(rels)) == 1 else "s", ", ".join(sorted(set(rels)))))
                    fh.write("-" * 100 + "\n")
                    fh.write("\n".join(lines) + "\n")
            used = sorted({o for p in by_file[pf] for e in proj[p]["blocks"].values() for o in e[3]})
            for o in used:
                named = sorted({r for p in by_file[pf] for e in proj[p]["blocks"].values() if o in e[3] for r in e[2]})
                fh.write("\n" + "=" * 100 + "\nOrigin: %s (named by %s)\n" % (o, ", ".join(named)) + "=" * 100 + "\n")
                fh.write(origin_texts[o] + "\n")
            if pf == "libstdc++":
                fh.write("\n" + "=" * 100 + "\nGCC Runtime Library Exception\n" + "=" * 100 + "\n")
                fh.write("libgcc and libstdc++ are linked statically into the binaries and the headers above are\n"
                         "compiled into the libvpl dispatcher. They are licensed under the GNU General Public License\n"
                         "version 3 or later with the GCC Runtime Library Exception, version 3.1:\n\n")
                fh.write("\n".join(rle) + "\n")
        summary.append("%s: %s" % (out_name, ", ".join("%s %d files" % (p, len(proj[p]["files"])) for p in by_file[pf])))

    print("notices: %d FFmpeg blocks from %d files (%s), %d origins; %d objects, %d files scanned; "
          "external: %d files of %d projects; %d unused allow-list entries"
          % (len(notices), len({f for f, _, _, _ in notices}), ", ".join(fams), len(origin_texts), len(objects),
             len(files), len(ext.files), len(proj), len(unused)))
    for s in summary:
        print("  " + s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
