import Foundation

// Run the real exporter, so the blob writers and the archive it builds are
// checked by executing them rather than by reading them. Compiled and run in
// CI against check_drt.py, which knows what Resolve's own files look like.
//
//   swiftc -O EasyEditor/Services/DRTBlobs.swift \
//             EasyEditor/Services/ZipWriter.swift \
//             EasyEditor/Services/DRTExporter.swift \
//             Tools/DRTCheck/main.swift -o drtcheck

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: drtcheck <output.drt>\n".utf8))
    exit(2)
}

// The individual blobs, so a wrong byte is named rather than merely failing.
print("composite.0 \(DRTBlobs.effectFilters(composite: 0))")
print("composite.27 \(DRTBlobs.effectFilters(composite: DRTBlobs.Composite.foreground))")
print("composite.30 \(DRTBlobs.effectFilters(composite: DRTBlobs.Composite.lum))")
print("resolution \(DRTBlobs.resolution(width: 1080, height: 1920).hexadecimal)")
print("framerate \(DRTBlobs.frameRate(30).hexadecimal)")
print("timemap \(DRTBlobs.timemap(frames: 120, rate: 30))")
print("extents \(DRTBlobs.preConformExtents)")
print("keyvalue \(DRTBlobs.keyValue([
    .text("DbType", "BtVideoTime"),
    .int("NumFrames", .int, 120),
    .int("StartTime", .long, 0),
    .int("SampleRate", .uint, 44_100),
    .data("FrameRate", DRTBlobs.frameRate(30)),
]))")

// Then a whole timeline, in the shape the app exports: a matte under its take
// making a key, an ordinary clip above, and two audio tracks.
func source(_ name: String, audio: DRTExporter.Source.Audio? = nil)
    -> DRTExporter.Source {
    var source = DRTExporter.Source(url: URL(fileURLWithPath: "/tmp/\(name)"),
                                    name: name, directory: "__EASYEDITOR_MEDIA__")
    source.width = 1080
    source.height = 1920
    source.frames = 120
    source.rate = 30
    source.audio = audio
    return source
}

let take = source("take.mov", audio: .init(sampleRate: 44_100, channels: 1,
                                           samples: 176_400, codec: "AAC"))
let matte = source("take.matte.mov")
let broll = source("broll.mov")
var voice = source("voiceover.m4a", audio: .init(sampleRate: 44_100, channels: 1,
                                                 samples: 176_400, codec: "AAC"))
voice.isVideo = false
var takeAudio = take
takeAudio.isVideo = false

let timeline = DRTExporter.Timeline(
    name: "Check & <Export>", width: 1080, height: 1920, rate: 30,
    video: [
        [DRTExporter.Clip(source: matte, start: 0, duration: 120,
                          composite: DRTBlobs.Composite.lum)],
        [DRTExporter.Clip(source: take, start: 0, duration: 120,
                          composite: DRTBlobs.Composite.foreground)],
        [DRTExporter.Clip(source: broll, start: 120, duration: 120)],
    ],
    audio: [
        [DRTExporter.Clip(source: voice, start: 0, duration: 120)],
        [DRTExporter.Clip(source: takeAudio, start: 0, duration: 120)],
    ])

do {
    try DRTExporter.write(timeline, to: URL(fileURLWithPath: arguments[1]))
    print("wrote \(arguments[1])")
} catch {
    FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
    exit(1)
}
