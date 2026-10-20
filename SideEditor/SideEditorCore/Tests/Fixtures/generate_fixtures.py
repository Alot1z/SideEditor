#!/usr/bin/env python3
"""Generate the SideEditorCore test fixture corpus.

Everything here is synthetic. No Apple binary, no third-party app, and no
personal data is involved: the "apps" are a handful of bytes with a plist.

The generator writes raw ZIP records instead of using `zipfile`, because half of
the corpus is *invalid on purpose* — a name of `../../evil`, a declared size that
disagrees with the data, a 0xFFFF entry count. `zipfile` validates those away.

Determinism: every record uses a fixed DOS timestamp and a fixed ordering, so
re-running the script reproduces byte-identical fixtures.

Usage: python3 SideEditor/SideEditorCore/Tests/Fixtures/generate_fixtures.py
"""

from __future__ import annotations

import binascii
import os
import plistlib
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

# 1980-01-01 00:00:00, the earliest DOS timestamp.
DOS_TIME = 0x0000
DOS_DATE = 0x0021

LOCAL_HEADER = 0x04034B50
CENTRAL_HEADER = 0x02014B50
EOCD = 0x06054B50

UNIX_REGULAR = 0o100644
UNIX_DIRECTORY = 0o040755


def deflate(data: bytes, level: int = 9) -> bytes:
    compressor = zlib.compressobj(level, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


class Entry:
    """One file record.

    `payload` overrides the bytes actually written; `declared_compressed` and
    `declared_size` override what the headers claim. That gap is the point of
    several fixtures.
    """

    def __init__(
        self,
        name: str,
        data: bytes = b"",
        method: int = 0,
        *,
        mode: int | None = None,
        flags: int = 0,
        payload: bytes | None = None,
        declared_compressed: int | None = None,
        declared_size: int | None = None,
        crc: int | None = None,
        version_made_by: int = 0x031E,
    ) -> None:
        self.name = name
        self.data = data
        self.method = method
        self.flags = flags
        self.version_made_by = version_made_by
        if payload is None:
            payload = data if method == 0 else deflate(data)
        self.payload = payload
        self.declared_compressed = len(payload) if declared_compressed is None else declared_compressed
        self.declared_size = len(data) if declared_size is None else declared_size
        self.crc = (binascii.crc32(data) & 0xFFFFFFFF) if crc is None else crc
        if mode is None:
            self.external_attr = 0
        else:
            self.external_attr = mode << 16


def build_zip(
    entries: list[Entry],
    *,
    comment: bytes = b"",
    declared_entry_count: int | None = None,
    cd_size_delta: int = 0,
    cd_offset_delta: int = 0,
) -> bytes:
    out = bytearray()
    central = bytearray()

    for entry in entries:
        offset = len(out)
        name = entry.name.encode("utf-8")
        out += struct.pack(
            "<IHHHHHIIIHH",
            LOCAL_HEADER,
            20,
            entry.flags,
            entry.method,
            DOS_TIME,
            DOS_DATE,
            entry.crc,
            entry.declared_compressed,
            entry.declared_size,
            len(name),
            0,
        )
        out += name
        out += entry.payload

        central += struct.pack(
            "<IHHHHHHIIIHHHHHII",
            CENTRAL_HEADER,
            entry.version_made_by,
            20,
            entry.flags,
            entry.method,
            DOS_TIME,
            DOS_DATE,
            entry.crc,
            entry.declared_compressed,
            entry.declared_size,
            len(name),
            0,
            0,
            0,
            0,
            entry.external_attr,
            offset,
        )
        central += name

    cd_offset = len(out)
    out += central
    count = len(entries) if declared_entry_count is None else declared_entry_count
    out += struct.pack(
        "<IHHHHIIH",
        EOCD,
        0,
        0,
        count,
        count,
        len(central) + cd_size_delta,
        cd_offset + cd_offset_delta,
        len(comment),
    )
    out += comment
    return bytes(out)


def directory(name: str) -> Entry:
    return Entry(name, b"", 0, mode=UNIX_DIRECTORY, declared_size=0)


def info_plist(
    bundle_id: str,
    executable: str,
    *,
    fmt: int = plistlib.FMT_XML,
    extra: dict | None = None,
) -> bytes:
    payload = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": "Example",
        "CFBundleExecutable": executable,
        "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "15.0",
        "UIFileSharingEnabled": True,
        "BuildNumber": 7,
    }
    if extra:
        payload.update(extra)
    return plistlib.dumps(payload, fmt=fmt, sort_keys=True)


def app_entries(
    *,
    app: str = "Payload/Example.app",
    bundle_id: str = "com.example.app",
    executable: str = "Example",
    method: int = 0,
    plist_format: int = plistlib.FMT_XML,
    extra_entries: list[Entry] | None = None,
    extra_plist: dict | None = None,
    include_payload_directory: bool = True,
) -> list[Entry]:
    entries = [
        directory(f"{app}/"),
        Entry(
            f"{app}/Info.plist",
            info_plist(bundle_id, executable, fmt=plist_format, extra=extra_plist),
            method,
            mode=UNIX_REGULAR,
        ),
        Entry(f"{app}/{executable}", b"\xcf\xfa\xed\xfe" + b"\x00" * 60, method, mode=UNIX_REGULAR),
    ]
    if include_payload_directory:
        entries.insert(0, directory("Payload/"))
    if extra_entries:
        entries.extend(extra_entries)
    return entries


def write(name: str, payload: bytes) -> None:
    path = os.path.join(HERE, name)
    with open(path, "wb") as handle:
        handle.write(payload)
    print(f"{os.path.basename(path):34s} {len(payload):8d} bytes")


def generate_valid() -> None:
    write(
        "valid-minimal.ipa",
        build_zip(app_entries()),
    )

    write(
        "valid-stored.ipa",
        build_zip(
            app_entries(
                extra_entries=[
                    directory("Payload/Example.app/Frameworks/"),
                    Entry(
                        "Payload/Example.app/Frameworks/CoreKit.framework/Info.plist",
                        plistlib.dumps(
                            {
                                "CFBundleIdentifier": "com.example.corekit",
                                "CFBundlePackageType": "FMWK",
                            },
                            sort_keys=True,
                        ),
                        mode=UNIX_REGULAR,
                    ),
                    Entry(
                        "Payload/Example.app/Frameworks/CoreKit.framework/CoreKit",
                        b"\xcf\xfa\xed\xfe" + b"\x11" * 32,
                        mode=UNIX_REGULAR,
                    ),
                    directory("Payload/Example.app/Frameworks/Raw.framework/"),
                    Entry(
                        "Payload/Example.app/Frameworks/Raw.framework/Raw",
                        b"\x00" * 16,
                        mode=UNIX_REGULAR,
                    ),
                    directory("Payload/Example.app/PlugIns/"),
                    Entry(
                        "Payload/Example.app/PlugIns/Widget.appex/Info.plist",
                        plistlib.dumps(
                            {
                                "CFBundleIdentifier": "com.example.app.widget",
                                "CFBundlePackageType": "XPC!",
                            },
                            sort_keys=True,
                        ),
                        mode=UNIX_REGULAR,
                    ),
                    Entry(
                        "Payload/Example.app/PlugIns/Widget.appex/Widget",
                        b"\xcf\xfa\xed\xfe" + b"\x22" * 24,
                        mode=UNIX_REGULAR,
                    ),
                    directory("Payload/Example.app/PlugIns/Bare.appex/"),
                    Entry(
                        "Payload/Example.app/PlugIns/Bare.appex/Bare",
                        b"\x33" * 8,
                        mode=UNIX_REGULAR,
                    ),
                ]
            )
        ),
    )

    write(
        "valid-deflate.ipa",
        build_zip(
            app_entries(
                bundle_id="com.example.deflated",
                method=8,
                plist_format=plistlib.FMT_BINARY,
                extra_entries=[
                    directory("Payload/Example.app/PlugIns/"),
                    Entry(
                        "Payload/Example.app/PlugIns/Share.appex/Info.plist",
                        plistlib.dumps(
                            {
                                "CFBundleIdentifier": "com.example.deflated.share",
                                "NSExtension": {"NSExtensionPointIdentifier": "com.apple.share-services"},
                            },
                            fmt=plistlib.FMT_BINARY,
                            sort_keys=True,
                        ),
                        8,
                        mode=UNIX_REGULAR,
                    ),
                ],
            )
        ),
    )

    # Directory-ness without a trailing slash: the entries below are directories
    # only by their Unix mode, which is how some archivers write them.
    write(
        "valid-directory-modes.ipa",
        build_zip(
            [
                Entry("Payload", b"", 0, mode=UNIX_DIRECTORY, declared_size=0),
                Entry("Payload/Example.app", b"", 0, mode=UNIX_DIRECTORY, declared_size=0),
                Entry(
                    "Payload/Example.app/Info.plist",
                    info_plist("com.example.modes", "Example"),
                    mode=UNIX_REGULAR,
                ),
                Entry(
                    "Payload/Example.app/Example",
                    b"\xcf\xfa\xed\xfe" + b"\x00" * 60,
                    mode=UNIX_REGULAR,
                ),
                Entry("Payload/Example.app/Resources", b"", 0, mode=UNIX_DIRECTORY, declared_size=0),
            ]
        ),
    )

    nested = build_zip(app_entries(app="Payload/Inner.app", bundle_id="com.example.inner"))
    write(
        "valid-nested.ipa",
        build_zip(
            app_entries(
                bundle_id="com.example.outer",
                extra_entries=[
                    directory("Payload/Example.app/PlugIns/"),
                    Entry(
                        "Payload/Example.app/PlugIns/Helper.ipa",
                        nested,
                        8,
                        mode=UNIX_REGULAR,
                    ),
                ],
            )
        ),
    )


def generate_hostile() -> None:
    # --- path policy -------------------------------------------------------
    write(
        "traversal-parent.ipa",
        build_zip([Entry("../../evil.txt", b"owned", 0, mode=UNIX_REGULAR)]),
    )
    write(
        "traversal-absolute.ipa",
        build_zip([Entry("/etc/evil.txt", b"owned", 0, mode=UNIX_REGULAR)]),
    )
    write(
        "traversal-windows-drive.ipa",
        build_zip([Entry("C:/Windows/evil.txt", b"owned", 0, mode=UNIX_REGULAR)]),
    )
    write(
        "traversal-backslash.ipa",
        build_zip([Entry("..\\..\\evil.txt", b"owned", 0, mode=UNIX_REGULAR)]),
    )
    write(
        "traversal-nul.ipa",
        build_zip([Entry("Payload/Example.app/Info.plist\x00.png", b"owned", 0, mode=UNIX_REGULAR)]),
    )

    # --- entry types -------------------------------------------------------
    write(
        "symlink-entry.ipa",
        build_zip([Entry("Payload/Example.app/link", b"/etc/passwd", 0, mode=0o120777)]),
    )
    write(
        "special-file-entry.ipa",
        build_zip([Entry("Payload/Example.app/fifo", b"", 0, mode=0o010644)]),
    )
    write(
        "duplicate-entry.ipa",
        build_zip(
            [
                Entry("Payload/Example.app/Info.plist", info_plist("com.example.app", "Example"), mode=UNIX_REGULAR),
                Entry("Payload/Example.app/Info.plist", info_plist("com.example.evil", "Example"), mode=UNIX_REGULAR),
            ]
        ),
    )

    # --- archive structure -------------------------------------------------
    write("not-a-zip.ipa", b"PK\x03\x04" + b"this is not a zip archive at all" * 8)
    write(
        "zip64-eocd.ipa",
        build_zip(app_entries(), declared_entry_count=0xFFFF),
    )
    write(
        "truncated-archive.ipa",
        build_zip(app_entries(), cd_size_delta=512),
    )
    write(
        "encrypted-entry.ipa",
        build_zip([Entry("Payload/Example.app/Info.plist", b"secret", 0, flags=0x0001, mode=UNIX_REGULAR)]),
    )
    write(
        "unsupported-method.ipa",
        build_zip([Entry("Payload/Example.app/Info.plist", b"x", 99, payload=b"x", mode=UNIX_REGULAR)]),
    )
    write(
        "no-payload.ipa",
        build_zip([Entry("readme.txt", b"not an ipa", 0, mode=UNIX_REGULAR)]),
    )
    write(
        "multiple-apps.ipa",
        build_zip(
            app_entries(
                app="Payload/One.app",
                bundle_id="com.example.one",
                include_payload_directory=True,
            )
            + app_entries(
                app="Payload/Two.app",
                bundle_id="com.example.two",
                include_payload_directory=False,
            )
        ),
    )
    write(
        "missing-plist.ipa",
        build_zip([Entry("Payload/Example.app/Example", b"\xcf\xfa\xed\xfe", 0, mode=UNIX_REGULAR)]),
    )
    write(
        "missing-executable.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    info_plist("com.example.app", "Ghost"),
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )
    write(
        "deep-nested-archive.ipa",
        build_zip(
            app_entries(
                extra_entries=[
                    Entry("Payload/Example.app/a/b/c/d/e/f/g/h/deep.ipa", b"PK", 0, mode=UNIX_REGULAR),
                ]
            )
        ),
    )

    # --- size and decompression -------------------------------------------
    write(
        "bomb-declared-huge.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"x",
                    8,
                    payload=deflate(b"x"),
                    declared_size=3 * 1024 * 1024 * 1024,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )
    write(
        "bomb-ratio.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"x",
                    8,
                    payload=deflate(b"\x00" * 64),
                    declared_size=1024 * 1024 * 1024,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )

    # 1 MiB of incompressible bytes inside a deflate stream that claims to be
    # only 64 KiB: the listing numbers look plausible (ratio ~1), and the
    # decoder has to stop at the declared ceiling.
    incompressible = bytes((index * 37 + 11) % 251 for index in range(1024 * 1024))
    write(
        "bomb-inflate.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"",
                    8,
                    payload=deflate(incompressible, level=0),
                    declared_size=64 * 1024,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )
    write(
        "corrupt-deflate.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"",
                    8,
                    payload=b"\xff\xff\xff\xff",
                    declared_size=16,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )
    write(
        "checksum-mismatch.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"payload",
                    8,
                    crc=0xDEADBEEF,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )
    write(
        "size-mismatch.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"a" * 100,
                    8,
                    declared_size=200,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )
    write(
        "truncated-payload.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    b"abc",
                    0,
                    declared_compressed=4096,
                    mode=UNIX_REGULAR,
                )
            ]
        ),
    )

    # --- property lists ----------------------------------------------------
    write(
        "malformed-plist.ipa",
        build_zip(
            [Entry("Payload/Example.app/Info.plist", b"\x00\x01\x02\x03not a plist", 0, mode=UNIX_REGULAR)]
        ),
    )
    write(
        "mistyped-plist.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": 42,
                            "CFBundleExecutable": "Example",
                        },
                        sort_keys=True,
                    ),
                    mode=UNIX_REGULAR,
                ),
                Entry("Payload/Example.app/Example", b"\xcf\xfa\xed\xfe", 0, mode=UNIX_REGULAR),
            ]
        ),
    )

    # `InspectionLimits.maxPlistDepth` is 64 and counts container edges from the
    # root, so 63 nested arrays put their innermost value at depth 64 (allowed)
    # and 64 nested arrays put it at 65 (rejected). The fixture uses 64: one past
    # the documented boundary, and shallow enough that no plist parser has an
    # opinion about the file itself.
    deep: object = "leaf"
    for _ in range(64):
        deep = [deep]
    write(
        "deep-plist.ipa",
        build_zip(
            [
                Entry(
                    "Payload/Example.app/Info.plist",
                    plistlib.dumps(
                        {"CFBundleIdentifier": "com.example.app", "Deep": deep},
                        sort_keys=True,
                    ),
                    mode=UNIX_REGULAR,
                ),
                Entry("Payload/Example.app/Example", b"\xcf\xfa\xed\xfe", 0, mode=UNIX_REGULAR),
            ]
        ),
    )


def main() -> None:
    generate_valid()
    generate_hostile()


if __name__ == "__main__":
    main()
