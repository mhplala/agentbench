import Foundation
import Network

// Loopback OpenAI **Responses API → chat/completions** translator.
//
// Newer codex only speaks the Responses API (wire_api="chat" was removed), but many
// relays (xiaomi mimo, and others) only expose /chat/completions. This proxy accepts
// codex's POST /responses on 127.0.0.1, calls the upstream /chat/completions, and
// synthesizes the Responses SSE event stream codex expects.
//
// Stateless: the upstream base URL is base64url-encoded into the request PATH and the
// API key arrives via codex's own `Authorization: Bearer` header — so multiple lanes
// with different relays can share one proxy. Bound to loopback only.
final class CodexRelayProxy: @unchecked Sendable {
    static let shared = CodexRelayProxy()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "app.agentbench.codexrelay")

    func start() {
        queue.async {
            guard self.listener == nil else { return }
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            guard let l = try? NWListener(using: params) else { return }
            l.stateUpdateHandler = { if case .ready = $0 { self.port = l.port?.rawValue ?? 0 } }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: self.queue)
            self.listener = l
        }
    }

    // The base_url to hand codex: encodes the real upstream so the proxy is stateless.
    // Returns nil until the listener is ready.
    func baseURL(forUpstream upstream: String) -> String? {
        guard port != 0 else { return nil }
        let enc = Data(upstream.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "http://127.0.0.1:\(port)/\(enc)"
    }

    private func decodeUpstream(_ seg: String) -> String? {
        var s = seg.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let u = String(data: d, encoding: .utf8) else { return nil }
        return u
    }

    // MARK: connection

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readAll(conn, buffer: Data())
    }

    // Read until we have the full request (headers + Content-Length body).
    private func readAll(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
                let header = String(data: headerData, encoding: .utf8) ?? ""
                let bodyStart = headerEnd.upperBound
                let have = buf.count - bodyStart
                let need = contentLength(header)
                if have >= need {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + need))
                    self.handle(conn, header: header, body: body)
                    return
                }
            }
            if isComplete || error != nil || buf.count > 16 * 1024 * 1024 {
                self.fail(conn, 400, "bad request"); return
            }
            self.readAll(conn, buffer: buf)
        }
    }

    private func contentLength(_ header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let p = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2, p[0].lowercased() == "content-length" { return Int(p[1]) ?? 0 }
        }
        return 0
    }

    private func bearer(_ header: String) -> String {
        for line in header.components(separatedBy: "\r\n") {
            let p = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2, p[0].lowercased() == "authorization" {
                return p[1].replacingOccurrences(of: "Bearer ", with: "")
            }
        }
        return ""
    }

    private func handle(_ conn: NWConnection, header: String, body: Data) {
        let reqLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { fail(conn, 400, "bad request"); return }
        let path = String(parts[1])
        // /<b64-upstream>/responses
        let segs = path.split(separator: "/").map(String.init)
        guard let first = segs.first, let upstream = decodeUpstream(first) else {
            fail(conn, 404, "missing upstream"); return
        }
        let key = bearer(header)
        let method = String(parts[0])
        let rest = "/" + segs.dropFirst().joined(separator: "/")   // e.g. /responses or /models
        // Only /responses needs translation; everything else (e.g. GET /models, which
        // codex polls to refresh its model list) is passed straight through.
        guard rest == "/responses" else {
            Task { await self.passthrough(conn, method: method, upstream: upstream, rest: rest, key: key, body: body) }
            return
        }
        guard let reqObj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            fail(conn, 400, "bad json"); return
        }
        let chat = Self.responsesToChat(reqObj)
        Task { await self.forward(conn, upstream: upstream, key: key, chat: chat) }
    }

    // MARK: translate request (Responses → chat/completions)

    // Responses roles include `developer` (and `system`); chat/completions providers
    // only accept system/user/assistant/tool, so normalize developer → system.
    static func chatRole(_ r: String?) -> String {
        switch r {
        case "system", "developer": return "system"
        case "assistant": return "assistant"
        case "tool": return "tool"
        default: return "user"
        }
    }

    static func responsesToChat(_ r: [String: Any]) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let instr = r["instructions"] as? String, !instr.isEmpty {
            messages.append(["role": "system", "content": instr])
        }
        func textOf(_ content: Any?) -> String {
            if let s = content as? String { return s }
            guard let arr = content as? [[String: Any]] else { return "" }
            return arr.compactMap { ($0["text"] as? String) }.joined()
        }
        if let input = r["input"] as? String {
            messages.append(["role": "user", "content": input])
        } else if let items = r["input"] as? [[String: Any]] {
            for it in items {
                switch it["type"] as? String {
                case "message", .none:
                    messages.append(["role": chatRole(it["role"] as? String), "content": textOf(it["content"])])
                case "function_call":
                    let call: [String: Any] = ["id": it["call_id"] ?? it["id"] ?? "", "type": "function",
                        "function": ["name": it["name"] ?? "", "arguments": it["arguments"] ?? "{}"]]
                    messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [call]])
                case "function_call_output":
                    messages.append(["role": "tool", "tool_call_id": it["call_id"] ?? "",
                                     "content": textOf(it["output"]) ])
                default: break
                }
            }
        }
        var chat: [String: Any] = ["model": r["model"] ?? "", "messages": messages, "stream": false]
        // Responses tools are flat {type:function, name, description, parameters} →
        // chat tools nest under "function".
        if let tools = r["tools"] as? [[String: Any]] {
            let mapped: [[String: Any]] = tools.compactMap { t in
                guard (t["type"] as? String) == "function" else { return nil }
                return ["type": "function", "function": [
                    "name": t["name"] ?? "",
                    "description": t["description"] ?? "",
                    "parameters": t["parameters"] ?? ["type": "object", "properties": [:]],
                ]]
            }
            if !mapped.isEmpty { chat["tools"] = mapped; chat["tool_choice"] = "auto" }
        }
        if let mt = r["max_output_tokens"] { chat["max_tokens"] = mt }
        if let temp = r["temperature"] { chat["temperature"] = temp }
        return chat
    }

    // MARK: forward + synthesize Responses SSE

    private func forward(_ conn: NWConnection, upstream: String, key: String, chat: [String: Any]) async {
        let base = upstream.hasSuffix("/") ? String(upstream.dropLast()) : upstream
        guard let url = URL(string: base + "/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: chat) else {
            fail(conn, 500, "bad upstream url"); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = bodyData
        req.timeoutInterval = 600

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                let tail = String(data: data.prefix(600), encoding: .utf8) ?? ""
                writeSSEError(conn, "上游 \(code): \(tail)")
                return
            }
            writeResponsesSSE(conn, chatResponse: obj, model: (chat["model"] as? String) ?? "")
        } catch {
            writeSSEError(conn, "上游请求失败: \(error.localizedDescription)")
        }
    }

    // Pass a non-/responses request (e.g. GET /models) straight to the upstream.
    private func passthrough(_ conn: NWConnection, method: String, upstream: String, rest: String, key: String, body: Data) async {
        let base = upstream.hasSuffix("/") ? String(upstream.dropLast()) : upstream
        guard let url = URL(string: base + rest) else { fail(conn, 500, "bad url"); return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if !body.isEmpty { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.timeoutInterval = 60
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            var out = Data("HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(data)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        } catch {
            fail(conn, 502, "upstream error")
        }
    }

    // Build the Responses event stream codex consumes from a full chat completion.
    private func writeResponsesSSE(_ conn: NWConnection, chatResponse: [String: Any], model: String) {
        let choice = (chatResponse["choices"] as? [[String: Any]])?.first
        let msg = choice?["message"] as? [String: Any]
        let text = (msg?["content"] as? String) ?? ""
        let reasoning = (msg?["reasoning_content"] as? String) ?? (msg?["reasoning"] as? String) ?? ""
        let toolCalls = (msg?["tool_calls"] as? [[String: Any]]) ?? []
        let usage = chatResponse["usage"] as? [String: Any]
        let respId = "resp_" + UUID().uuidString.prefix(24)

        var seq = 0
        var sse = Data()
        func emit(_ type: String, _ payload: [String: Any]) {
            var p = payload; p["type"] = type; p["sequence_number"] = seq; seq += 1
            guard let d = try? JSONSerialization.data(withJSONObject: p) else { return }
            sse.append(Data("event: \(type)\r\n".utf8))
            sse.append(Data("data: ".utf8)); sse.append(d); sse.append(Data("\r\n\r\n".utf8))
        }

        var output: [[String: Any]] = []
        let baseResp: [String: Any] = ["id": respId, "object": "response", "model": model, "status": "in_progress"]
        emit("response.created", ["response": baseResp])
        emit("response.in_progress", ["response": baseResp])

        var idx = 0
        // reasoning: chat providers return the thinking as `reasoning_content`; surface
        // it as a Responses reasoning item so codex (and thus AgentBench) shows it.
        if !reasoning.isEmpty {
            let itemId = "rs_" + UUID().uuidString.prefix(20)
            let item: [String: Any] = ["id": itemId, "type": "reasoning", "summary": []]
            emit("response.output_item.added", ["output_index": idx, "item": item])
            let part: [String: Any] = ["type": "summary_text", "text": ""]
            emit("response.reasoning_summary_part.added", ["item_id": itemId, "output_index": idx, "summary_index": 0, "part": part])
            emit("response.reasoning_summary_text.delta", ["item_id": itemId, "output_index": idx, "summary_index": 0, "delta": reasoning])
            emit("response.reasoning_summary_text.done", ["item_id": itemId, "output_index": idx, "summary_index": 0, "text": reasoning])
            let donePart: [String: Any] = ["type": "summary_text", "text": reasoning]
            emit("response.reasoning_summary_part.done", ["item_id": itemId, "output_index": idx, "summary_index": 0, "part": donePart])
            let doneItem: [String: Any] = ["id": itemId, "type": "reasoning",
                                           "summary": [["type": "summary_text", "text": reasoning]]]
            emit("response.output_item.done", ["output_index": idx, "item": doneItem])
            output.append(doneItem); idx += 1
        }
        // assistant text message
        if !text.isEmpty {
            let itemId = "msg_" + UUID().uuidString.prefix(20)
            let item: [String: Any] = ["id": itemId, "type": "message", "role": "assistant", "status": "in_progress", "content": []]
            emit("response.output_item.added", ["output_index": idx, "item": item])
            let part: [String: Any] = ["type": "output_text", "text": "", "annotations": []]
            emit("response.content_part.added", ["item_id": itemId, "output_index": idx, "content_index": 0, "part": part])
            emit("response.output_text.delta", ["item_id": itemId, "output_index": idx, "content_index": 0, "delta": text])
            emit("response.output_text.done", ["item_id": itemId, "output_index": idx, "content_index": 0, "text": text])
            let donePart: [String: Any] = ["type": "output_text", "text": text, "annotations": []]
            emit("response.content_part.done", ["item_id": itemId, "output_index": idx, "content_index": 0, "part": donePart])
            let doneItem: [String: Any] = ["id": itemId, "type": "message", "role": "assistant", "status": "completed",
                                           "content": [["type": "output_text", "text": text, "annotations": []]]]
            emit("response.output_item.done", ["output_index": idx, "item": doneItem])
            output.append(doneItem); idx += 1
        }
        // function calls
        for tc in toolCalls {
            let fn = tc["function"] as? [String: Any]
            let name = (fn?["name"] as? String) ?? ""
            let argsStr = (fn?["arguments"] as? String) ?? "{}"
            let callId = (tc["id"] as? String) ?? ("call_" + UUID().uuidString.prefix(12))
            let itemId = "fc_" + UUID().uuidString.prefix(20)
            let item: [String: Any] = ["id": itemId, "type": "function_call", "name": name,
                                       "call_id": callId, "arguments": "", "status": "in_progress"]
            emit("response.output_item.added", ["output_index": idx, "item": item])
            emit("response.function_call_arguments.delta", ["item_id": itemId, "output_index": idx, "delta": argsStr])
            emit("response.function_call_arguments.done", ["item_id": itemId, "output_index": idx, "arguments": argsStr])
            let doneItem: [String: Any] = ["id": itemId, "type": "function_call", "name": name,
                                           "call_id": callId, "arguments": argsStr, "status": "completed"]
            emit("response.output_item.done", ["output_index": idx, "item": doneItem])
            output.append(doneItem); idx += 1
        }

        var finalResp: [String: Any] = ["id": respId, "object": "response", "model": model,
                                        "status": "completed", "output": output]
        if let usage {
            finalResp["usage"] = ["input_tokens": usage["prompt_tokens"] ?? 0,
                                  "output_tokens": usage["completion_tokens"] ?? 0,
                                  "total_tokens": usage["total_tokens"] ?? 0]
        }
        emit("response.completed", ["response": finalResp])

        var out = Data("HTTP/1.1 200 OK\r\n".utf8)
        out.append(Data("Content-Type: text/event-stream\r\n".utf8))
        out.append(Data("Cache-Control: no-store\r\n".utf8))
        out.append(Data("Connection: close\r\n\r\n".utf8))
        out.append(sse)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func writeSSEError(_ conn: NWConnection, _ message: String) {
        let payload: [String: Any] = ["type": "response.failed",
            "response": ["status": "failed", "error": ["message": message]]]
        var sse = Data("event: response.failed\r\ndata: ".utf8)
        sse.append((try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8))
        sse.append(Data("\r\n\r\n".utf8))
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
        out.append(sse)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func fail(_ conn: NWConnection, _ code: Int, _ msg: String) {
        let body = Data(msg.utf8)
        var out = Data("HTTP/1.1 \(code) Error\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
