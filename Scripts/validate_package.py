#!/usr/bin/env python3
"""Read-only FlatGlass RootHide .deb gate; no external tools or extraction."""

import argparse
import gzip
import hashlib
import io
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import struct
import sys
import tarfile
import xml.parsers.expat
import zlib


PACKAGE = "local.lumid.flatglass"
VERSION = "1.8.4+roothide.test2"
ARCH = "iphoneos-arm64e"
TWEAKS = "Library/MobileSubstrate/DynamicLibraries"
BUNDLE = "Library/PreferenceBundles/FlatGlassPrefs.bundle"
PRINCIPAL = "FGSettingsListController"
TOOL = "usr/libexec/flatglass"
MAINTAINER_SCRIPTS = ("preinst", "postinst", "prerm", "postrm", "extrainst_")
LIMIT = 32 << 20  # Each compressed .deb and inflated tar; this package is < 2 MiB.
ARM64 = 0x0100000C
ARCHS = {0: "arm64", 2: "arm64e"}
IOS15 = 15 << 16
ROOTLESS = b"/var/jb"


class InvalidPackage(ValueError):
    pass


def check(condition, message):
    if not condition:
        raise InvalidPackage(message)


def read_ar(deb):
    check(deb.startswith(b"!<arch>\n"), "not a Debian ar archive")
    offset, members = 8, {}
    allowed = {"debian-binary", "control.tar.gz", "data.tar.gz"}
    while offset < len(deb):
        header = deb[offset:offset + 60]
        check(len(header) == 60 and header[-2:] == b"`\n", "invalid ar header")
        name = header[:16].decode("ascii").rstrip().removesuffix("/")
        check(name in allowed and name not in members,
              f"unexpected or duplicate ar member {name!r}; build with gzip compression")
        size = header[48:58].strip()
        check(size.isdigit(), "invalid ar member size")
        start = offset + 60
        end = start + int(size)
        offset = end + (int(size) & 1)
        check(offset <= len(deb) and (end == offset or deb[end:offset] == b"\n"),
              f"truncated {name} or invalid ar padding")
        members[name] = deb[start:end]
    check(list(members) == ["debian-binary", "control.tar.gz", "data.tar.gz"]
          and members["debian-binary"] == b"2.0\n", "expected a Debian 2.0 gzip package")
    return read_tar(members["control.tar.gz"]), read_tar(members["data.tar.gz"])


def read_tar(compressed):
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as gz:
        raw = gz.read(LIMIT + 1)
    check(len(raw) <= LIMIT, "inflated tar exceeds size limit")
    entries = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tar:
        for member in tar:
            name = member.name
            path = PurePosixPath(name)
            key = path.as_posix()
            check(len(entries) < 2048, "too many tar entries")
            check(not path.is_absolute() and ".." not in path.parts and "\\" not in name
                  and not any(ord(c) < 32 or ord(c) == 127 for c in name),
                  f"unsafe tar path {name!r}")
            check(ROOTLESS not in f"/{key}".encode("utf-8"), f"rootless tar path {name!r}")
            check(key not in entries and (key != "." or member.isdir()),
                  f"duplicate or invalid tar path {name!r}")
            check(member.type in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE)
                  and member.sparse is None and 0 <= member.size <= LIMIT,
                  f"unsupported tar member {name!r} (links and special files are not allowed)")
            # Read regular-file bytes only; never extract, follow links, or invoke scripts.
            content = tar.extractfile(member).read() if member.isfile() else None
            entries[key] = (member.mode & 0o7777, content)
        tail = raw[tar.offset:]
        check(len(tail) >= 1024 and len(raw) % 512 == 0 and not any(tail),
              "invalid or missing tar end markers")
    for key in entries:
        for parent in PurePosixPath(key).parents:
            if parent.as_posix() in entries:
                check(entries[parent.as_posix()][1] is None, f"non-directory parent of {key!r}")
    return entries


def required(entries, name, mode=None):
    actual, content = entries.get(name, (0, None))
    check(content, f"missing or empty regular file {name}")
    if mode is not None:
        check(actual == mode, f"{name}: expected mode {mode:04o}, found {actual:04o}")
    return content


def plist(entries, name):
    def safe_strings(obj):
        if isinstance(obj, dict):
            return all(safe_strings(x) for pair in obj.items() for x in pair)
        if isinstance(obj, list):
            return all(map(safe_strings, obj))
        return not isinstance(obj, str) or ROOTLESS.decode() not in obj

    value = plistlib.loads(required(entries, name))
    check(isinstance(value, dict) and safe_strings(value), f"invalid or rootless plist {name}")
    return value


def check_filter(entries, name, executable):
    data = required(entries, name)
    if data.lstrip().startswith(b"{"):
        # Restricted to the original OpenStep filter schema, not a generic plist parser.
        source = re.sub(r"/\*.*?\*/|//[^\n]*", "", data.decode("utf-8"), flags=re.S)
        token = re.escape(executable)
        syntax = r'\{\s*Filter\s*=\s*\{\s*Executables\s*=\s*\(\s*(?:"%s"|%s)\s*,?\s*\)\s*;\s*\}\s*;\s*\}'
        check(re.fullmatch(syntax % (token, token), source.strip()), f"invalid OpenStep filter {name}")
    else:
        check(plist(entries, name) == {"Filter": {"Executables": [executable]}},
              f"wrong executable filter in {name}")


def check_control(entries):
    fields = {}
    for line in required(entries, "control").decode("utf-8").strip("\n").splitlines():
        if line.startswith((" ", "\t")):
            check(fields, "control continuation before first field")
            continue
        key, sep, value = line.partition(":")
        key = key.lower()
        check(sep and re.fullmatch(r"[a-z0-9-]+", key) and key not in fields,
              f"invalid or duplicate control field {key!r}")
        fields[key] = value.strip()
    for key, value in {"package": PACKAGE, "version": VERSION, "architecture": ARCH}.items():
        check(fields.get(key) == value, f"control {key}: expected {value}, found {fields.get(key)!r}")
    for name in MAINTAINER_SCRIPTS:
        if name in entries or name in ("postinst", "prerm"):
            required(entries, name, 0o755)


def verify_signature(image, offset, size):
    """Verify the embedded CodeDirectory page hashes, not trust/entitlements."""
    check(size >= 12 and offset + size <= len(image), "invalid LC_CODE_SIGNATURE range")
    blob = image[offset:offset + size]
    magic, length, count = struct.unpack_from(">III", blob)
    check(magic == 0xFADE0CC0 and 12 + 8 * count <= length <= size,
          "invalid embedded signature SuperBlob")
    found = {}
    for i in range(count):
        slot, start = struct.unpack_from(">II", blob, 12 + 8 * i)
        check(12 + 8 * count <= start <= length - 8, "invalid signature blob index")
        magic, size_i = struct.unpack_from(">II", blob, start)
        check(8 <= size_i <= length - start, "signature sub-blob out of bounds")
        if slot != 0 and not 0x1000 <= slot <= 0x1005:
            continue
        check(slot not in found and magic == 0xFADE0C02 and size_i >= 44,
              "missing or duplicate CodeDirectory")
        directory = blob[start:start + size_i]
        _, _, version, _, hash_off, _, special, pages, code_limit = struct.unpack_from(">9I", directory)
        hash_size, hash_type, _, page_shift = directory[36:40]
        algos = {1: ("sha1", 20), 2: ("sha256", 32), 3: ("sha256", 20), 4: ("sha384", 48)}
        algo, expected_size = algos.get(hash_type, ("", 0))
        check(algo and hash_size == expected_size and code_limit == offset and page_shift <= 30,
              "unsupported CodeDirectory hash type, page size, or signed range")
        if version >= 0x20100:
            check(size_i >= 48 and struct.unpack_from(">I", directory, 44)[0] == 0,
                  "scattered CodeDirectory pages are unsupported")
        page_size = (1 << page_shift) if page_shift else code_limit
        check(pages == (code_limit + page_size - 1) // page_size
              and 44 <= hash_off - special * hash_size
              and hash_off + pages * hash_size <= size_i, "invalid CodeDirectory hash table")
        for p in range(pages):
            begin = p * page_size
            digest = hashlib.new(algo, image[begin:min(begin + page_size, code_limit)]).digest()
            h = hash_off + p * hash_size
            check(digest[:hash_size] == directory[h:h + hash_size], f"signature page {p} hash mismatch")
        found[slot] = f"{algo}/{pages} pages"
    check(0 in found, "missing primary CodeDirectory")
    return ", ".join(found.values())


# Mach-O lc_str paths: dylib ID/dependencies, dylinker, rpaths, and dyld environment.
LOADER_COMMANDS = {0xC, 0xD, 0xE, 0xF, 0x18, 0x1C, 0x1F, 0x20, 0x23, 0x27}
VERSION_COMMANDS = {0x24, 0x25, 0x2F, 0x30, 0x32}


def check_slice(image, subtype, file_type, install_name):
    magic, cpu, sub, kind, ncmds, cmd_size = struct.unpack_from("<6I", image)
    check(magic == 0xFEEDFACF and cpu == ARM64 and sub & 0xFFFFFF == subtype,
          "fat table does not match a 64-bit ARM Mach-O header")
    check(kind == file_type, f"wrong Mach-O file type ({kind})")
    offset, end = 32, 32 + cmd_size
    check(offset <= end <= len(image) and ncmds <= cmd_size // 8, "invalid load-command table")
    signature, versions, ids, paths = [], [], [], []
    for _ in range(ncmds):
        check(offset + 8 <= end, "missing load command")
        command, size = struct.unpack_from("<II", image, offset)
        command &= 0x7FFFFFFF  # Mask LC_REQ_DYLD.
        check(8 <= size <= end - offset and size % 8 == 0, "invalid load-command size")
        if command in LOADER_COMMANDS:
            check(size >= 16, "truncated loader-path command")
            start = struct.unpack_from("<I", image, offset + 8)[0]
            minimum = 24 if command in {0xC, 0xD, 0x18, 0x1F, 0x20, 0x23} else 12
            check(minimum <= start < size, "invalid loader-path offset")
            path, nul, _ = image[offset + start:offset + size].partition(b"\0")
            check(path and nul and ROOTLESS not in path and ROOTLESS not in posixpath.normpath(path),
                  f"invalid or rootless loader path {path!r}")
            paths.append(path)
            if command == 0xD:
                ids.append(path)
        elif command in VERSION_COMMANDS:
            check(size >= (24 if command == 0x32 else 16), "truncated deployment target command")
            first, second = struct.unpack_from("<II", image, offset + 8)
            versions.append((first, second) if command == 0x32 else (2 if command == 0x25 else 0, first))
        elif command == 0x1D:
            check(size == 16, "invalid LC_CODE_SIGNATURE command")
            signature.append(struct.unpack_from("<II", image, offset + 8))
        offset += size
    check(offset == end, "load commands do not fill their declared size")
    check(versions == [(2, IOS15)], f"expected iOS 15.0 deployment target; found {versions!r}")
    check(ids == ([install_name] if install_name else []), f"wrong install name: {ids!r}")
    if file_type == 8:  # Settings bundle
        check(b"/System/Library/PrivateFrameworks/Preferences.framework/Preferences" in paths,
              "Settings bundle has no Preferences framework load command")
    check(len(signature) == 1 and signature[0][0] >= end, "missing or invalid LC_CODE_SIGNATURE")
    hashes = verify_signature(image, *signature[0])
    return f"{ARCHS[subtype]}: iOS 15.0, signature {signature[0][1]} B ({hashes})"


def check_macho(data, name, file_type):
    endian, wide = {
        b"\xca\xfe\xba\xbe": (">", False), b"\xca\xfe\xba\xbf": (">", True),
        b"\xbe\xba\xfe\xca": ("<", False), b"\xbf\xba\xfe\xca": ("<", True),
    }.get(data[:4], (None, False))
    check(endian and len(data) >= 8 and struct.unpack_from(endian + "I", data, 4)[0] == 2,
          f"{name}: expected a universal Mach-O with two slices")
    arch = struct.Struct(endian + ("IIQQII" if wide else "IIIII"))
    end = 8 + 2 * arch.size
    install_name = f"@loader_path/.jbroot/{name}".encode() if file_type == 6 else None
    reports, ranges = {}, []
    for i in range(2):
        cpu, sub, start, size, *_ = arch.unpack_from(data, 8 + i * arch.size)
        sub &= 0xFFFFFF
        check(cpu == ARM64 and sub in ARCHS and sub not in reports, f"{name}: unexpected or duplicate slice")
        stop = start + size
        check(size >= 32 and end <= start < stop <= len(data)
              and all(stop <= a or start >= b for a, b in ranges), f"{name}: invalid fat slice range")
        ranges.append((start, stop))
        try:
            reports[sub] = check_slice(data[start:stop], sub, file_type, install_name)
        except (InvalidPackage, struct.error) as error:
            raise InvalidPackage(f"{name} {ARCHS[sub]}: {error}") from error
    print(f"{name}: {'; '.join(reports[sub] for sub in ARCHS)}")
    if install_name:
        print(f"  LC_ID_DYLIB: {install_name.decode()}")


def validate(deb):
    control, payload = read_ar(deb)
    for entries in (control, payload):
        for name, (_, content) in entries.items():
            if content is not None and (entries is control or name.endswith((".plist", ".strings", ".sh"))):
                check(ROOTLESS not in content, f"rootless /var/jb reference in {name!r}")
    check_control(control)
    print(f"Package: {PACKAGE} {VERSION} {ARCH}")
    for tweak, executable in (("FlatGlassIconServices", "iconservicesagent"), ("FlatGlassRefresh", "SpringBoard")):
        stem = f"{TWEAKS}/{tweak}"
        check_filter(payload, stem + ".plist", executable)
        check_macho(required(payload, stem + ".dylib"), stem + ".dylib", 6)

    info = plist(payload, f"{BUNDLE}/Info.plist")
    check(info.get("CFBundleIdentifier") == f"{PACKAGE}.preferences"
          and info.get("CFBundlePrincipalClass") == PRINCIPAL
          and info.get("CFBundleExecutable") == "FlatGlassPrefs", "Settings bundle Info.plist does not match")
    items = plist(payload, f"{BUNDLE}/Root.plist").get("items")
    check(isinstance(items, list) and items, "Settings Root.plist must contain items")
    for language in ("en", "ru"):
        required(payload, f"{BUNDLE}/{language}.lproj/FlatGlass.strings")
    registration = plist(payload, "Library/PreferenceLoader/Preferences/FlatGlassPrefs.plist").get("entry")
    check(isinstance(registration, dict) and registration.get("bundle") == "FlatGlassPrefs"
          and registration.get("detail") == PRINCIPAL and registration.get("isController") is True,
          "PreferenceLoader registration does not match the Settings bundle")
    check_macho(required(payload, f"{BUNDLE}/FlatGlassPrefs"), f"{BUNDLE}/FlatGlassPrefs", 8)
    check_macho(required(payload, TOOL, 0o755), TOOL, 2)

    job_path = f"Library/LaunchDaemons/{PACKAGE}.plist"
    required(payload, job_path, 0o644)
    job = plist(payload, job_path)
    check(job.get("Label") == PACKAGE and job.get("ProgramArguments") == [f"/{TOOL}", "--watch"]
          and job.get("Program", f"/{TOOL}") == f"/{TOOL}"
          and (job.get("UserName"), job.get("GroupName")) == ("mobile", "mobile"),
          "LaunchDaemon does not match the mobile --watch job")
    print("Verified filters, Settings resources/registration, mobile LaunchDaemon and script modes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("deb", type=Path)
    args = parser.parse_args()
    try:
        check(args.deb.is_file(), "input must be a regular .deb file")
        with args.deb.open("rb") as source:
            data = source.read(LIMIT + 1)
        check(len(data) <= LIMIT, "compressed .deb exceeds size limit")
        validate(data)
    except (OSError, ValueError, EOFError, tarfile.TarError, struct.error,
            xml.parsers.expat.ExpatError, zlib.error, RecursionError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"SHA256: {hashlib.sha256(data).hexdigest()}")
    print("PASS: package structure and embedded Mach-O code-page hashes only; no device trust or install test.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
