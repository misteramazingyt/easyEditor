import Foundation
import Network
import Combine

/// A small HTTP server so the desktop can fetch an export straight off the
/// phone — same Wi-Fi, one URL, no cable and no cloud round trip.
///
/// It serves exactly two things: a page saying what is on offer, and the
/// archive itself. It listens only while the export sheet is open, and it has
/// no way to reach anything but the one file it was handed.
@MainActor
final class ExportServer: ObservableObject {

    @Published private(set) var address: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?
    /// Bumped each time the archive is fetched, so the UI can say so.
    @Published private(set) var downloads = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var package: ProjectPackager.Package?
    private var projectName = ""
    private let port: NWEndpoint.Port = 8207

    // MARK: - Lifecycle

    func start(package: ProjectPackager.Package, projectName: String) {
        stop()
        self.package = package
        self.projectName = projectName
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, port: port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.address = self.map { "http://\($0.localIP() ?? "?"):\($0.port)" }
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        isRunning = false
        address = nil
    }

    // MARK: - Serving

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, error == nil else {
                    connection.cancel()
                    return
                }
                var buffer = accumulated
                if let data { buffer.append(data) }
                // Wait for the end of the request head before answering.
                guard let head = String(data: buffer, encoding: .utf8),
                      head.contains("\r\n\r\n") || isComplete else {
                    self.receive(on: connection, accumulated: buffer)
                    return
                }
                let path = head.split(separator: "\r\n").first
                    .map { $0.split(separator: " ") }
                    .flatMap { $0.count > 1 ? String($0[1]) : nil } ?? "/"
                self.respond(to: path, on: connection)
            }
        }
    }

    private func respond(to path: String, on connection: NWConnection) {
        guard let package else {
            send(status: "404 Not Found", contentType: "text/plain",
                 body: Data("Nothing to export.".utf8), on: connection)
            return
        }
        if path.hasPrefix("/download") {
            guard let data = try? Data(contentsOf: package.url, options: .mappedIfSafe) else {
                send(status: "500 Internal Server Error", contentType: "text/plain",
                     body: Data("The archive couldn't be read.".utf8), on: connection)
                return
            }
            downloads += 1
            send(status: "200 OK", contentType: "application/zip", body: data,
                 on: connection,
                 extraHeaders: ["Content-Disposition":
                                "attachment; filename=\"\(package.fileName)\""])
            return
        }
        send(status: "200 OK", contentType: "text/html; charset=utf-8",
             body: Data(indexPage(package).utf8), on: connection)
    }

    private func send(status: String, contentType: String, body: Data,
                      on connection: NWConnection,
                      extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (key, value) in extraHeaders { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func indexPage(_ package: ProjectPackager.Package) -> String {
        let megabytes = String(format: "%.1f", Double(package.byteCount) / 1_048_576)
        var notes = ""
        if !package.notes.isEmpty {
            notes = "<ul>" + package.notes
                .map { "<li>\($0.replacingOccurrences(of: "&", with: "&amp;"))</li>" }
                .joined() + "</ul>"
        }
        return """
        <!doctype html><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(projectName) — EasyEditor</title>
        <style>
          :root { color-scheme: dark; }
          body { margin:0; min-height:100vh; display:grid; place-items:center;
                 background:#0d0f14; color:#e9edf5;
                 font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif; }
          main { max-width:34rem; padding:2rem 1.25rem; }
          h1 { font-size:1.4rem; margin:0 0 .25rem; }
          p.sub { margin:0 0 1.5rem; color:#96a0b5; }
          a.get { display:inline-block; background:#2b7cf6; color:#fff; text-decoration:none;
                  padding:.7rem 1.4rem; border-radius:.6rem; font-weight:600; }
          ol { color:#c6cede; padding-left:1.2rem; }
          code { background:#191d26; padding:.1rem .35rem; border-radius:.25rem; }
          ul { color:#c8a36a; }
        </style>
        <main>
          <h1>\(projectName)</h1>
          <p class="sub">FCPXML + media, \(megabytes) MB</p>
          <p><a class="get" href="/download">Download the archive</a></p>
          <ol>
            <li>Unpack it somewhere you'll leave it.</li>
            <li>Resolve → File → Import → Timeline → <em>Import AAF, EDL, XML…</em></li>
            <li>Pick the <code>.fcpxml</code>.</li>
            <li>If anything comes in offline, run <code>python3 relink.py</code> beside it.</li>
          </ol>
          \(notes)
        </main>
        """
    }

    // MARK: - Where we are

    /// The Wi-Fi address, which is the one the desktop can reach.
    private func localIP() -> String? {
        var address: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            // en0 is Wi-Fi on a phone; the rest are cellular or loopback.
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: host)
            }
        }
        return address
    }
}
