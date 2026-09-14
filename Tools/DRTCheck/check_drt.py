#!/usr/bin/env python3
"""Check what the Swift DRT exporter actually produced.

The .drt format is undocumented and reverse-engineered, so the exporter is
guarded by running it rather than by reading it: `drtcheck` writes a timeline
and prints the individual blobs, and this reads both back.

The expected blob values are what Resolve itself wrote, byte for byte.

    python3 check_drt.py <drtcheck stdout> <the .drt it wrote>
"""
import re
import struct
import sys
import zipfile

# Read off files Resolve exported, for a clip at each composite mode.
EXPECTED = {
    "composite.0":
        "000000020000001f800a0608024a004a000a14082c4a004a004a08085c1a040a0220024a004a00",
    "composite.27":
        "0000000200000027800a0e08024a0808001a040a02201b4a000a14082c4a004a004a08085c1a04"
        "0a0220024a004a00",
    "composite.30":
        "0000000200000027800a0e08024a0808001a040a02201e4a000a14082c4a004a004a08085c1a04"
        "0a0220024a004a00",
    "resolution": "00000000000004380000000000000780",
    "framerate": "0000000000003e400000000000000000",
    "timemap": "02400fbbbbbbbbbbbc",
    "extents": "00000100000030c20000010000003042",
}

LEN_PREFIXED = {10, 12}
WIDTHS = {1: 1, 4: 8, 6: 8}

failures = []


def fail(message):
    failures.append(message)
    print("  FAIL %s" % message)


def kv_read(raw):
    """Walk a key/value blob, returning its fields and whether it consumed
    exactly — a blob that does not consume exactly is a blob Resolve will
    misread."""
    count = int.from_bytes(raw[4:8], "big")
    i, fields = 8, []
    for _ in range(count):
        klen = int.from_bytes(raw[i:i + 4], "big")
        i += 4
        key = raw[i:i + klen].decode("utf-16-be")
        i += klen
        typ = int.from_bytes(raw[i:i + 4], "big")
        i += 4
        i += 1  # every value carries a flag byte, whatever its type
        if typ in LEN_PREFIXED:
            vlen = int.from_bytes(raw[i:i + 4], "big")
            i += 4
            value = raw[i:i + vlen]
            i += vlen
            if typ == 10:
                value = value.decode("utf-16-be")
        else:
            width = WIDTHS.get(typ, 4)
            value = int.from_bytes(raw[i:i + width], "big")
            i += width
        fields.append((key, typ, value))
    return fields, i == len(raw)


def check_blobs(path):
    print("blobs")
    printed = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 2:
                printed[parts[0]] = parts[1]
    for name, expected in EXPECTED.items():
        actual = printed.get(name)
        if actual is None:
            fail("%s was not printed" % name)
        elif actual != expected:
            fail("%s\n    expected %s\n    actual   %s" % (name, expected, actual))
        else:
            print("  ok %s" % name)

    raw = printed.get("keyvalue")
    if not raw:
        fail("keyvalue was not printed")
        return
    fields, exact = kv_read(bytes.fromhex(raw))
    if not exact:
        fail("keyvalue does not consume exactly")
    wanted = [("DbType", 10, "BtVideoTime"), ("NumFrames", 2, 120),
              ("StartTime", 6, 0), ("SampleRate", 3, 44100)]
    for expected, actual in zip(wanted, fields):
        if expected != actual:
            fail("keyvalue field %r, expected %r" % (actual, expected))
    if len(fields) != 5:
        fail("keyvalue has %d fields, expected 5" % len(fields))
    else:
        print("  ok keyvalue round-trips")


def check_archive(path):
    print("archive")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        contents = {name: archive.read(name).decode("utf-8") for name in names}
    print("  ok opens as a zip: %s" % ", ".join(sorted(names)))

    if len(names) != 3:
        fail("expected 3 files, found %d" % len(names))
    if "project.xml" not in names:
        fail("no project.xml")
    pool = next((n for n in names if "MpFolder" in n), None)
    seq = next((n for n in names if n.startswith("SeqContainer/")), None)
    if not pool or not seq:
        fail("missing the media pool or the sequence")
        return

    # The sequence file is named after the container it holds, not after the
    # sequence inside it -- getting that wrong makes Resolve import nothing.
    container = re.search(r'<Sm2SequenceContainer DbId="([^"]+)"', contents[seq])
    if not container:
        fail("no Sm2SequenceContainer")
    elif seq != "SeqContainer/%s.xml" % container.group(1):
        fail("sequence file %s does not match container %s"
             % (seq, container.group(1)))
    else:
        print("  ok sequence file matches its container")

    unbalanced = [name for name, text in contents.items()
                  if text.count("<Element>") != text.count("</Element>")]
    for name in unbalanced:
        text = contents[name]
        fail("%s has unbalanced <Element> (%d open, %d close)"
             % (name, text.count("<Element>"), text.count("</Element>")))
    if not unbalanced:
        print("  ok every <Element> is balanced")

    # Nothing may still carry the template's own identity, or Resolve matches
    # the timeline to one it already holds and the import does nothing.
    joined = "".join(contents.values())
    for stale in ("69bcc5bb-bd88-4ebc-8d46-454fb8467aae",):
        if stale in joined:
            fail("the template's identity %s survived the remap" % stale)
    print("  ok the template's identities were replaced")

    for tag, expected in (("Sm2TiTrack", 5), ("Sm2TiVideoClip", 3),
                          ("Sm2TiAudioClip", 2), ("Sm2MpVideoClip", 3),
                          ("Sm2MpAudioClip", 1)):
        found = contents[seq].count("<%s " % tag) + contents[pool].count("<%s " % tag)
        if found != expected:
            fail("%d %s, expected %d" % (found, tag, expected))
        else:
            print("  ok %d %s" % (found, tag))

    for mode, label in ((EXPECTED["composite.30"], "Lum"),
                        (EXPECTED["composite.27"], "Foreground")):
        if mode not in contents[seq]:
            fail("no clip set to %s" % label)
        else:
            print("  ok a clip is set to %s" % label)

    # Every generated blob has to parse, or Resolve reads garbage out of it.
    checked = 0
    for tag in ("Time", "Geometry", "Proxy", "VideoMetadata", "TracksBA"):
        for found in re.findall(r"<%s>([0-9a-fA-F]+)</%s>" % (tag, tag), contents[pool]):
            fields, exact = kv_read(bytes.fromhex(found))
            if not exact:
                fail("a %s blob does not consume exactly" % tag)
            checked += 1
    print("  ok %d key/value blobs parse exactly" % checked)

    # The protobuf blobs are written uncompressed on purpose, so relink.py can
    # reach the media path inside them without a zstd decoder.
    clips = re.findall(r"<Clip>([0-9a-fA-F]+)</Clip>", contents[pool])
    for found in clips:
        raw = bytes.fromhex(found)
        if raw[8] != 0x80:
            fail("a Clip blob is not raw protobuf (flag 0x%02x)" % raw[8])
        if struct.unpack(">I", raw[4:8])[0] != len(raw) - 8:
            fail("a Clip blob's length field disagrees with its size")
    print("  ok %d Clip blobs are raw and correctly sized" % len(clips))

    if "__EASYEDITOR_MEDIA__" not in contents[seq]:
        fail("the media placeholder is missing, so relink.py has nothing to find")
    else:
        print("  ok the media placeholder is there for relink.py")

    if "&amp;" not in contents[pool] or "&lt;" not in contents[pool]:
        fail("the timeline name was not escaped")
    else:
        print("  ok the timeline name is escaped")


check_blobs(sys.argv[1])
check_archive(sys.argv[2])
print()
if failures:
    sys.exit("%d check%s failed" % (len(failures), "" if len(failures) == 1 else "s"))
print("the DRT exporter produced what Resolve expects")
