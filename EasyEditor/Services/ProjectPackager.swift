import Foundation

/// Gather a project into one archive: the timeline as FCPXML, every file it
/// refers to, and a script that points the one at the other once it has been
/// unpacked somewhere.
///
/// The zip is made by NSFileCoordinator's `.forUploading`, which is the system
/// zipper — no third-party archiver, and it produces exactly the folder you
/// dropped in.
enum ProjectPackager {

    struct Package {
        let url: URL
        let fileName: String
        let byteCount: Int
        /// Things that could not cross over, for the README and the UI.
        let notes: [String]
    }

    static func makeArchive(for project: VideoProject) async throws -> Package {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(project.id.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let folderName = safeName(project.name)
        let staging = root.appendingPathComponent(folderName, isDirectory: true)
        let mediaOut = staging.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaOut, withIntermediateDirectories: true)

        // Only the files the timeline actually uses.
        var copied = Set<String>()
        var mattes: [String] = []
        for clip in project.clips {
            guard let fileName = clip.fileName, !copied.contains(fileName) else { continue }
            let source = FilePaths.mediaURL(projectID: project.id, fileName: fileName)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.copyItem(
                at: source,
                to: mediaOut.appendingPathComponent(FCPXMLExporter.exportName(for: fileName)))
            copied.insert(fileName)

            // A keyed take carries its alpha in a layer only Apple
            // decodes. Send the silhouette along as an ordinary
            // greyscale movie so the transparency can be put back.
            if await MatteExporter.hasAlpha(url: source) {
                let matteName = MatteExporter.matteName(for: fileName)
                do {
                    try await MatteExporter.write(
                        from: source,
                        to: mediaOut.appendingPathComponent(matteName))
                    mattes.append(matteName)
                } catch {
                    Log.engine.error("Matte for \(fileName) failed: \(error.localizedDescription)")
                }
            }
        }

        let media = await FCPXMLExporter.gather(project: project)
        let xml = FCPXMLExporter.xml(for: project, media: media)
        try xml.write(to: staging.appendingPathComponent("\(folderName).fcpxml"),
                      atomically: true, encoding: .utf8)

        var notes: [String] = []

        // The .drt is the one to import: FCPXML cannot carry a composite mode,
        // so the key on a take has to be switched on by hand or by script
        // afterwards, whereas Resolve's own format arrives with it already set.
        // The FCPXML stays in the box as the readable fallback.
        var wroteDRT = false
        do {
            let package = await DRTExporter.timeline(for: project, media: media)
            try DRTExporter.write(package.timeline,
                                  to: staging.appendingPathComponent("\(folderName).drt"))
            notes.append(contentsOf: package.notes)
            wroteDRT = true
        } catch {
            Log.engine.error("DRT export failed: \(error.localizedDescription)")
            notes.append("The Resolve timeline (.drt) couldn't be written, so only the "
                         + "FCPXML is here — the keyed takes will need set_matte_modes.py.")
        }
        if !mattes.isEmpty, !wroteDRT {
            notes.append("\(mattes.count) keyed take\(mattes.count == 1 ? "" : "s") came over "
                         + "with a matte beside it — two dropdowns in Resolve, or one run of "
                         + "set_matte_modes.py, to switch the transparency on.")
        }
        let titles = project.clips.filter { $0.kind == .title }.count
        if titles > 0 {
            notes.append("\(titles) text clip\(titles == 1 ? "" : "s") — Resolve builds its "
                         + "titles its own way and receives neither format's, so these are "
                         + "left out.")
        }
        if project.clips.contains(where: { ($0.luts?.isEmpty == false) || $0.filter != .none }) {
            notes.append("Filters and LUTs stay here — Resolve has its own.")
        }
        if project.aesthetic?.isActive == true {
            notes.append("The aesthetic treatment (CRT/VHS/NTSC) is not exportable.")
        }
        if project.clips.contains(where: { $0.motionKeys?.isActive == true || $0.inOut != nil }) {
            notes.append("Keyframed motion and in/out animation are not carried over.")
        }
        if project.clips.contains(where: { $0.mask != nil || $0.cutout != nil }) {
            notes.append("Masks and cut-outs are not carried over.")
        }

        try relinkScript(folderName: folderName)
            .write(to: staging.appendingPathComponent("relink.py"),
                   atomically: true, encoding: .utf8)
        try resolveScript()
            .write(to: staging.appendingPathComponent("set_matte_modes.py"),
                   atomically: true, encoding: .utf8)
        try readme(project: project, folderName: folderName,
                   notes: notes, mattes: mattes, wroteDRT: wroteDRT)
            .write(to: staging.appendingPathComponent("README.txt"),
                   atomically: true, encoding: .utf8)

        let zip = try zipDirectory(staging)
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        return Package(url: zip, fileName: "\(folderName).zip",
                       byteCount: size ?? 0, notes: notes)
    }

    // MARK: - Zipping

    private static func zipDirectory(_ directory: URL) throws -> URL {
        var archiveURL: URL?
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory,
                                       options: [.forUploading],
                                       error: &coordinatorError) { zipped in
            // The coordinator's file only lives for the length of this block.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(directory.lastPathComponent + ".zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
                archiveURL = destination
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        guard let archiveURL else {
            throw NSError(domain: "com.easyeditor.export", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "The archive couldn't be created.",
            ])
        }
        return archiveURL
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_")).inverted).joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "EasyEditor Project" : trimmed
    }

    // MARK: - What goes in the box

    /// Points both timelines at the media once the archive has been
    /// unpacked. Neither format can carry a path the app does not know,
    /// so both are written against a placeholder and rewritten here --
    /// including inside the .drt's binary blobs, which the exporter
    /// leaves uncompressed so this can reach into them.
    private static func relinkScript(folderName: String) -> String {
        """
        #!/usr/bin/env python3
        \"\"\"Point this export at wherever the folder now lives.

        Two timelines come in the box. The .drt is the one to import -- it is
        Resolve's own format and carries the composite modes that switch the
        transparency on. The .fcpxml is the readable fallback. Both refer to the
        media by path, and neither can know where you unpacked this, so this
        rewrites both to point at the Media folder beside it.

            python3 relink.py                 # rewrite in place
            python3 relink.py --media /path   # media somewhere else
            python3 relink.py --relative      # FCPXML back to relative paths

        A copy of each original is kept as <name>.bak the first time.
        \"\"\"

        import argparse
        import glob
        import os
        import pathlib
        import re
        import shutil
        import struct
        import sys
        import zipfile
        from urllib.parse import unquote, urlparse


        HERE = os.path.dirname(os.path.abspath(__file__))
        SRC = re.compile(r'src="([^"]*)"')
        # What the app writes in place of a folder it cannot know the name of.
        TOKEN = "__EASYEDITOR_MEDIA__"


        def basename(value):
            # The filename, from a plain path or a file:// URL, either slash.
            # A Windows file URL keeps the drive in the netloc rather than the
            # path, so going through urlparse().path alone drops everything
            # before it -- which reads as an empty filename, not as an error.
            if "://" in value:
                parsed = urlparse(value)
                value = unquote((parsed.netloc or "") + (parsed.path or ""))
            # chr(92) is a backslash; spelling it this way keeps the script
            # free of escapes the app has to escape in turn.
            return os.path.basename(value.replace(chr(92), "/").rstrip("/"))


        def to_absolute(name, media_dir):
            # as_uri() knows what a file URL looks like on this platform.
            # Quoting a joined path by hand does not, and turns a drive letter
            # into percent-escapes that nothing will open.
            return pathlib.Path(os.path.join(media_dir, basename(name))).as_uri()


        def to_relative(name):
            return "./Media/" + basename(name)


        def relink_fcpxml(path, media_dir, relative):
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            missing = []

            def replace(match):
                value = match.group(1)
                if relative:
                    return 'src="%s"' % to_relative(value)
                base = basename(value)
                if not base:
                    return match.group(0)
                if not os.path.exists(os.path.join(media_dir, base)):
                    missing.append(base)
                return 'src="%s"' % to_absolute(value, media_dir)

            text, count = SRC.subn(replace, text)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
            return count, missing


        # --- the .drt ------------------------------------------------------------
        #
        # A .drt is a zip of three XML files. The media path appears twice per clip:
        # once as plain text in <MediaFilePath>, and once inside a hex-encoded blob
        # as a protobuf string field. The app writes those blobs uncompressed on
        # purpose, so this can reach into them without a zstd decoder.


        def varint(value):
            out = bytearray()
            while True:
                byte = value & 0x7F
                value >>= 7
                out.append(byte | (0x80 if value else 0))
                if not value:
                    return bytes(out)


        def retarget_blob(blob_hex, media_dir):
            \"\"\"Swap the directory inside a Clip blob, fixing both length fields.\"\"\"
            raw = bytearray.fromhex(blob_hex)
            needle = bytes([10]) + varint(len(TOKEN)) + TOKEN.encode("utf-8")
            start = raw.find(needle)
            if start < 0:
                return blob_hex, 0
            replacement_dir = media_dir.encode("utf-8")
            replacement = bytes([10]) + varint(len(replacement_dir)) + replacement_dir
            raw[start:start + len(needle)] = replacement
            # The header is [u32 version][u32 length of everything after it].
            if len(raw) >= 8:
                body = len(raw) - 8
                raw[4:8] = struct.pack(">I", body)
            return bytes(raw).hex(), 1


        def relink_drt(path, media_dir):
            with zipfile.ZipFile(path) as archive:
                names = archive.namelist()
                contents = {name: archive.read(name).decode("utf-8") for name in names}

            count = 0
            missing = []
            for name, text in contents.items():
                def path_replace(match):
                    value = match.group(1)
                    base = basename(value)
                    if not base:
                        return match.group(0)
                    if not os.path.exists(os.path.join(media_dir, base)):
                        missing.append(base)
                    # Resolve wants a plain path here, not a URL.
                    return "<MediaFilePath>%s</MediaFilePath>" % os.path.join(media_dir, base)

                text, changed = re.subn(r"<MediaFilePath>([^<]*)</MediaFilePath>",
                                        path_replace, text)
                count += changed

                def blob_replace(match):
                    fixed, changed = retarget_blob(match.group(1), media_dir)
                    return ">%s<" % fixed

                text = re.sub(r">([0-9a-fA-F]{32,})<", blob_replace, text)
                contents[name] = text

            with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
                for name in names:
                    archive.writestr(name, contents[name].encode("utf-8"))
            return count, missing


        def main():
            parser = argparse.ArgumentParser(description=__doc__)
            parser.add_argument("--media", default=os.path.join(HERE, "Media"),
                                help="where the media actually is")
            parser.add_argument("--relative", action="store_true",
                                help="write ./Media/... into the FCPXML instead of "
                                     "absolute URLs; the .drt always takes absolute "
                                     "paths, so it is left alone")
            args = parser.parse_args()

            media_dir = os.path.abspath(args.media)
            if not args.relative and not os.path.isdir(media_dir):
                sys.exit("No media folder at %s" % media_dir)

            jobs = [(p, relink_fcpxml) for p in glob.glob(os.path.join(HERE, "*.fcpxml"))]
            if not args.relative:
                jobs += [(p, relink_drt) for p in glob.glob(os.path.join(HERE, "*.drt"))]
            if not jobs:
                sys.exit("No timeline next to this script.")

            for path, relink in jobs:
                backup = path + ".bak"
                if not os.path.exists(backup):
                    shutil.copy2(path, backup)
                if relink is relink_fcpxml:
                    count, missing = relink(path, media_dir, args.relative)
                else:
                    count, missing = relink(path, media_dir)
                print("%s: rewrote %d path%s" % (os.path.basename(path), count,
                                                 "" if count == 1 else "s"))
                for name in sorted(set(missing)):
                    print("  ! not found in the media folder: %s" % name)


        if __name__ == "__main__":
            main()
        """
    }

    /// Sets the two blend modes that turn a matte pair into a key.
    ///
    /// Resolve composites this natively on the Edit page: the matte set to
    /// Lum, the take above it set to Foreground. No Fusion, no external
    /// mattes, no colour page. FCPXML cannot carry a blend mode, so this walks
    /// the imported timeline afterwards and sets them — the numbers are
    /// Resolve's own enumeration, read back off clips set by hand.
    private static func resolveScript() -> String {
        """
        #!/usr/bin/env python3
        # Pair every keyed take with its matte, in an already-imported timeline.
        #
        #   Resolve > Workspace > Console  (switch to Py3), then:
        #       exec(open(r"<this file>").read())
        #
        # or run it outside Resolve with RESOLVE_SCRIPT_API set the usual way.
        #
        # It touches nothing but the Composite Mode of clips it can pair, so
        # running it twice is harmless.

        import glob
        import os
        import sys

        # Resolve's own Composite Mode enumeration, read back off clips set by
        # hand in the Inspector -- there is no published list of these.
        FOREGROUND = 27
        LUM = 30
        MATTE_SUFFIX = ".matte.mov"
        HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else os.getcwd()


        def get_resolve():
            try:
                import DaVinciResolveScript as dvr
                return dvr.scriptapp("Resolve")
            except ImportError:
                pass
            try:
                # Inside Resolve's own console the object is already there.
                return resolve  # noqa: F821
            except NameError:
                return None


        def main():
            app = get_resolve()
            if app is None:
                sys.exit("Couldn't reach Resolve. Run this from its console, "
                         "or set up the scripting API first.")
            project = app.GetProjectManager().GetCurrentProject()
            if project is None:
                sys.exit("No project open.")
            timeline = project.GetCurrentTimeline()
            if timeline is None:
                # Nothing open: import the edit sitting beside this script.
                xml = sorted(glob.glob(os.path.join(HERE, "*.fcpxml")))
                if not xml:
                    sys.exit("No timeline open, and no .fcpxml beside this script.")
                pool = project.GetMediaPool()
                if not pool.ImportTimelineFromFile(xml[0]):
                    sys.exit("Couldn't import %s. Import it by hand "
                             "(File > Import > Timeline) and run this again."
                             % os.path.basename(xml[0]))
                timeline = project.GetCurrentTimeline()
                if timeline is None:
                    sys.exit("The import didn't leave a timeline open.")
                print("Imported %s." % os.path.basename(xml[0]))

            # Everything on every video track, with the track it sits on.
            items = []
            for track in range(1, int(timeline.GetTrackCount("video")) + 1):
                for item in timeline.GetItemListInTrack("video", track) or []:
                    items.append((track, item))

            mattes = [(t, i) for t, i in items if i.GetName().endswith(MATTE_SUFFIX)]
            if not mattes:
                sys.exit("No .matte.mov clips on this timeline — nothing to pair.")

            paired = 0
            orphans = []
            for track, matte in mattes:
                base = matte.GetName()[: -len(MATTE_SUFFIX)]
                take = None
                for other_track, item in items:
                    if other_track <= track:
                        continue
                    name = item.GetName()
                    if name.startswith(base) and not name.endswith(MATTE_SUFFIX):
                        # The one that actually overlaps it in time.
                        if item.GetStart() < matte.GetEnd() and item.GetEnd() > matte.GetStart():
                            take = item
                            break
                if take is None:
                    orphans.append(matte.GetName())
                    continue
                matte.SetProperty("CompositeMode", LUM)
                take.SetProperty("CompositeMode", FOREGROUND)
                paired += 1

            print("Paired %d matte%s." % (paired, "" if paired == 1 else "s"))
            for name in orphans:
                print("  ! no take above this matte: %s" % name)


        main()

        """
    }

    private static func readme(project: VideoProject, folderName: String,
                               notes: [String], mattes: [String],
                               wroteDRT: Bool) -> String {
        var text = """
        \(project.name)
        Exported from EasyEditor.

        What's here
          \(folderName).drt      the timeline, in Resolve's own format
          \(folderName).fcpxml   the same edit as FCPXML 1.8, as a fallback
          Media/                 every file the timeline uses
          relink.py              points both at the media, wherever you put it

        Getting it into DaVinci Resolve
          1. Unpack this folder somewhere you're happy to leave it.
          2. Run:  python3 relink.py
             Neither file can know where you unpacked this, so both are written
             against a placeholder and this fills in the real paths. Moved the
             media elsewhere afterwards? Run it again with --media /path.
          3. Resolve > File > Import > Timeline > Import AAF, EDL, XML...
             Pick the .drt.

        Import the .drt, not the .fcpxml. It is Resolve's own format, so it
        arrives as the timeline it is -- including the composite modes that
        switch your keyed takes' transparency back on, which no interchange
        format can carry. The .fcpxml is there because it is the readable,
        documented one: it carries clip speed and volume that the .drt does
        not, and it is a working way in if the .drt ever stops being one.


        """
        if !mattes.isEmpty {
            text += """
            About the transparency
              Your keyed takes were recorded as HEVC with alpha, which keeps
              them small and which only Apple's decoders read: the alpha sits
              in a layer Resolve on Windows and ffmpeg both ignore, and it is
              premultiplied, so ignoring it fills the key in with black rather
              than merely flattening it.

              So each keyed take comes with a matte beside it -- an ordinary
              black-and-white movie, white where you are -- on the track
              directly below. Resolve composites that natively, on the Edit
              page, with nothing but a pair of blend modes:

                  the matte           Composite Mode: Lum
                  the take above it   Composite Mode: Foreground


            """
            if wroteDRT {
                text += """
                  The .drt arrives with both already set. Nothing to do.

                  If you import the .fcpxml instead, FCPXML has no way to carry
                  a blend mode, so you get the matte and the take on the right
                  tracks with the modes unset. Two dropdowns per take in the
                  Inspector, or open Resolve's console (Workspace > Console,
                  switch it to Py3) and run:

                      exec(open(r"<this folder>/set_matte_modes.py").read())


                """
            } else {
                text += """
                  The .drt could not be written this time, so the modes are not
                  set. Two dropdowns per take in the Inspector, or open
                  Resolve's console (Workspace > Console, switch it to Py3):

                      exec(open(r"<this folder>/set_matte_modes.py").read())

                  With no timeline open it imports the .fcpxml beside it first,
                  so that one line does the whole job. It touches nothing but
                  the modes, so running it twice is safe.


                """
            }
        }
        if !notes.isEmpty {
            text += "What didn't come with it\n"
            for note in notes { text += "  - \(note)\n" }
            text += "\nEverything else — the cuts, the trims, the tracks and "
                + "the keys — is in the timeline.\n"
        }
        return text
    }
}
