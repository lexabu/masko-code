import Foundation
import Network

@Observable
final class LocalServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    let port: UInt16 = Constants.serverPort
    private var stopped = false

    var onEventReceived: ((ClaudeEvent) -> Void)?
    var onPermissionRequest: ((ClaudeEvent, NWConnection) -> Void)?
    /// Custom input endpoint: `POST /input {"name":"x","value":true}`
    var onInputReceived: ((String, ConditionValue) -> Void)?

    func start() throws {
        stopped = false
        // Cancel any existing listener before creating a new one
        listener?.cancel()
        listener = nil

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        listener = try NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    print("[masko-desktop] Server listening on port \(self.port)")
                case .failed(let error):
                    self.isRunning = false
                    self.listener?.cancel()
                    self.listener = nil
                    guard !self.stopped else { return }
                    print("[masko-desktop] Server failed: \(error) — retrying in 5s...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        guard !self.stopped else { return }
                        try? self.start()
                    }
                default:
                    break
                }
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        var receivedData = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data {
                    receivedData.append(data)
                }

                // Process as soon as we have a complete HTTP request (headers + body),
                // OR when the connection closes / errors.
                // This avoids a deadlock where curl keeps the connection open waiting
                // for a response (e.g. PermissionRequest with --max-time 120) but
                // the server never processes the request because isComplete is false.
                if self?.hasCompleteHTTPRequest(receivedData) == true || isComplete || error != nil {
                    self?.processRequest(receivedData, connection: connection)
                } else {
                    readMore()
                }
            }
        }

        readMore()
    }

    /// Check if we have a complete HTTP request (headers + full body per Content-Length).
    private func hasCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let str = String(data: data, encoding: .utf8) else { return false }

        // GET requests are complete once we see the header terminator
        if str.hasPrefix("GET ") {
            return str.contains("\r\n\r\n")
        }

        // POST: need header terminator + Content-Length bytes
        guard let separatorRange = str.range(of: "\r\n\r\n") else { return false }
        let headers = str[str.startIndex..<separatorRange.lowerBound]
        let body = str[separatorRange.upperBound...]

        // Parse Content-Length header
        if let clRange = headers.range(of: "Content-Length: ", options: .caseInsensitive) {
            let afterCL = headers[clRange.upperBound...]
            if let lineEnd = afterCL.firstIndex(of: "\r"),
               let contentLength = Int(afterCL[afterCL.startIndex..<lineEnd]) {
                return body.utf8.count >= contentLength
            }
        }

        // No Content-Length → treat as complete if we have the separator
        return true
    }

    private func processRequest(_ data: Data, connection: NWConnection) {
        guard let httpString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Bad Request")
            return
        }

        // Extract first line to get method + path
        let firstLine = httpString.components(separatedBy: "\r\n").first ?? ""

        // Extract body for POST routes
        guard let bodyRange = httpString.range(of: "\r\n\r\n") else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "No body")
            return
        }
        let bodyString = String(httpString[bodyRange.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "Invalid body")
            return
        }

        // Route: POST /hook — receive Claude Code hook events
        if firstLine.contains("POST /hook") {
            let decoder = JSONDecoder()
            if let event = try? decoder.decode(ClaudeEvent.self, from: bodyData) {
                print("[masko-desktop] Hook received: \(event.hookEventName)")

                // PermissionRequest: hold connection open for user decision
                if event.eventType == .permissionRequest, let handler = onPermissionRequest {
                    DispatchQueue.main.async {
                        handler(event, connection)
                    }
                    // Do NOT send response — connection stays open until user decides
                    // Also forward to event processor for tracking
                    DispatchQueue.main.async { [weak self] in
                        self?.onEventReceived?(event)
                    }
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    self?.onEventReceived?(event)
                }
            } else {
                print("[masko-desktop] Hook received but failed to decode JSON")
            }
            sendResponse(connection: connection, status: "200 OK", body: "OK")
            return
        }

        // Route: POST /input — set a custom input on the state machine
        // Body: {"name":"myVar","value":true} or {"name":"myVar","value":42}
        if firstLine.contains("POST /input") {
            if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
               let name = json["name"] as? String {
                let conditionValue: ConditionValue
                if let b = json["value"] as? Bool {
                    conditionValue = .bool(b)
                } else if let n = json["value"] as? Double {
                    conditionValue = .number(n)
                } else if let n = json["value"] as? Int {
                    conditionValue = .number(Double(n))
                } else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "value must be bool or number")
                    return
                }
                print("[masko-desktop] Input received: \(name) = \(json["value"] ?? "nil")")
                DispatchQueue.main.async { [weak self] in
                    self?.onInputReceived?(name, conditionValue)
                }
                sendResponse(connection: connection, status: "200 OK", body: "OK")
            } else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "Expected {\"name\":\"...\",\"value\":...}")
            }
            return
        }

        sendResponse(connection: connection, status: "404 Not Found", body: "Not Found")
    }

    private func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    deinit {
        listener?.cancel()
    }
}
