import Foundation
import Network

// Tiny loopback-only static HTTP server for previewing agent artifacts.
//
// Agent output is loaded over http://127.0.0.1:<port>/… instead of file:// so that
// ES modules, <script type="importmap">, fetch(), and workers actually run — all of
// which browsers block on file:// origins. Bound to the loopback interface only.
final class PreviewServer: @unchecked Sendable {
    static let shared = PreviewServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var root: URL?
    private let queue = DispatchQueue(label: "app.agentbench.previewserver")

    func start(root: URL) {
        queue.async {
            self.root = root.standardizedFileURL
            guard self.listener == nil else { return }
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback     // never exposed off-device
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params) else { return }
            l.stateUpdateHandler = { state in
                if case .ready = state { self.port = l.port?.rawValue ?? 0 }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: self.queue)
            self.listener = l
        }
    }

    // Map a file on disk to its loopback URL (nil if not under root or not ready).
    func url(forFile fileURL: URL) -> URL? {
        guard port != 0, let root else { return nil }
        let fp = fileURL.standardizedFileURL.path
        let rp = root.path
        guard fp.hasPrefix(rp + "/") else { return nil }
        let rel = String(fp.dropFirst(rp.count)) // leading "/"
        let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
        return URL(string: "http://127.0.0.1:\(port)\(enc)")
    }

    // MARK: connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readHeader(conn, buffer: Data())
    }

    private func readHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let nl = buf.range(of: Data("\r\n".utf8)) {
                let line = String(data: buf.subdata(in: buf.startIndex..<nl.lowerBound), encoding: .utf8) ?? ""
                self.respond(conn, requestLine: line)
            } else if isComplete || error != nil || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.readHeader(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { send(conn, status: "405 Method Not Allowed"); return }
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
        path = path.removingPercentEncoding ?? path
        guard let root, !path.contains(".."), path.hasPrefix("/") else { send(conn, status: "400 Bad Request"); return }

        var fileURL = root.appendingPathComponent(String(path.dropFirst()))
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }
        // Resolve symlinks and confirm the final target is still inside root, so an
        // artifact can't drop a symlink pointing outside the runs dir and have it
        // served over loopback (the `..` check alone doesn't catch symlinks).
        let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == rootResolved.path
                || resolved.path.hasPrefix(rootResolved.path + "/") else {
            send(conn, status: "403 Forbidden"); return
        }
        guard let data = try? Data(contentsOf: resolved) else { send(conn, status: "404 Not Found"); return }
        send(conn, status: "200 OK", body: data, contentType: Self.mime(resolved.pathExtension))
    }

    private func send(_ conn: NWConnection, status: String, body: Data = Data(), contentType: String = "text/plain") {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var out = Data(header.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "text/javascript; charset=utf-8"   // required for ES modules
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "wasm":        return "application/wasm"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "map":         return "application/json"
        case "txt", "md":   return "text/plain; charset=utf-8"
        default:            return "application/octet-stream"
        }
    }
}
