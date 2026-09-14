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
        if !mattes.isEmpty {
            notes.append("\(mattes.count) keyed take\(mattes.count == 1 ? "" : "s") came over as a compound clip "
                         + "with its matte — one step in Resolve to switch the transparency on.")
        }
        let titles = project.clips.filter { $0.kind == .title }.count
        if titles > 0 {
            notes.append("\(titles) text clip\(titles == 1 ? "" : "s") — FCPXML titles don't "
                         + "survive the trip into Resolve, so these are left out.")
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
        try readme(project: project, folderName: folderName,
                   notes: notes, mattes: mattes)
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

    private static func relinkScript(folderName: String) -> String {
        """
        #!/usr/bin/env python3
        \"\"\"Point the FCPXML at wherever this folder now lives.

        The export writes media paths relative to the archive ("./Media/x.mov").
        Resolve resolves those against the XML's own location, which is usually
        enough. It is not enough when the XML has been moved away from the
        media, or when an importer insists on absolute paths -- so this rewrites
        them to absolute file:// URLs pointing at the Media folder next to this
        script.

            python3 relink.py                 # rewrite in place
            python3 relink.py --media /path   # media somewhere else
            python3 relink.py --relative      # put it back to relative paths

        A copy of the original is kept as <name>.fcpxml.bak the first time.
        \"\"\"

        import argparse
        import glob
        import os
        import pathlib
        import re
        import shutil
        import sys
        from urllib.parse import unquote, urlparse


        HERE = os.path.dirname(os.path.abspath(__file__))
        SRC = re.compile(r'src="([^"]*)"')


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


        def main():
            parser = argparse.ArgumentParser(description=__doc__)
            parser.add_argument("--media", default=os.path.join(HERE, "Media"),
                                help="where the media actually is")
            parser.add_argument("--relative", action="store_true",
                                help="write ./Media/... instead of absolute URLs")
            args = parser.parse_args()

            media_dir = os.path.abspath(args.media)
            if not args.relative and not os.path.isdir(media_dir):
                sys.exit("No media folder at %s" % media_dir)

            files = glob.glob(os.path.join(HERE, "*.fcpxml"))
            if not files:
                sys.exit("No .fcpxml next to this script.")

            for path in files:
                backup = path + ".bak"
                if not os.path.exists(backup):
                    shutil.copy2(path, backup)
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()

                missing = []

                def replace(match):
                    value = match.group(1)
                    if args.relative:
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
                print("%s: rewrote %d path%s" % (os.path.basename(path), count,
                                                 "" if count == 1 else "s"))
                for name in sorted(set(missing)):
                    print("  ! not found in the media folder: %s" % name)


        if __name__ == "__main__":
            main()

        """
    }

    private static func readme(project: VideoProject, folderName: String,
                               notes: [String], mattes: [String]) -> String {
        var text = """
        \(project.name)
        Exported from EasyEditor.

        What's here
          \(folderName).fcpxml   the timeline, FCPXML 1.8
          Media/                 every file the timeline uses
          relink.py              rewrites the media paths if you move things

        Getting it into DaVinci Resolve
          1. Unpack this folder somewhere you're happy to leave it.
          2. Resolve > File > Import > Timeline > Import AAF, EDL, XML...
          3. Pick the .fcpxml. Leave "Automatically import source clips into
             media pool" on.
          4. If Resolve asks where the media is, point it at the Media folder
             next to the XML.

        If the clips come in offline, run:
            python3 relink.py
        which rewrites the paths to absolute ones pointing at the Media folder
        beside it. Moved the media elsewhere? Use --media /path/to/media.


        """
        if !mattes.isEmpty {
            text += """
            Turning the transparency back on
              Your keyed takes were recorded as HEVC with alpha, which keeps
              them small and which only Apple's decoders read: the alpha sits
              in a separate layer that Resolve on Windows, and ffmpeg, both
              ignore. That layer is premultiplied, so where the background was
              keyed out the colour is black -- ignore the alpha and the key
              does not merely vanish, it fills in black.

              So each keyed take arrives as a compound clip named after the
              recording, holding two things: the picture, and its matte on the
              lane above -- white where you are, black where you are not.

              To switch it on, once per take:
                1. Open the compound clip (double-click it in the Media Pool).
                2. Select the picture, go to the Color page.
                3. Add the matte as a Layer/Alpha input, and connect it to the
                   node's Key input, then to Alpha Output.
                4. Close the compound. Every use of it on the timeline is now
                   transparent.

              The alternative is ProRes 4444, which carries alpha everywhere
              and runs about 40 MB a second -- this way the transfer stays
              small and the step is yours to take only where you need it.

            """
        }
        if !notes.isEmpty {
            text += "What didn't come with it\n"
            for note in notes { text += "  - \(note)\n" }
            text += "\nEverything else — the cuts, the trims, the lanes, speed "
                + "and clip volume — is in the XML.\n"
        }
        return text
    }
}
