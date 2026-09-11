// URLSession is allowed in this file. It talks only to the loopback interface (127.0.0.1 / localhost / ::1).
// The only other file in the package that may use a networking API is Models/ModelDownloader.swift.
import Foundation

public struct OllamaTag: Codable, Sendable, Equatable { public let name: String }

public enum OllamaError: Error, Sendable, Equatable {
    case notLoopback(String)
    case badResponse(String)
}

/// Talks to a local Ollama over plain URLSession. No SDK.
public final class OllamaCleaner: Cleaner, @unchecked Sendable {
    public let backend: CleanupBackend = .ollama
    private let lock = NSLock()
    private var _baseURL: URL
    private var _model: String
    private let session: URLSession

    public init(baseURL: String = "http://127.0.0.1:11434", model: String = "qwen3:4b") throws {
        guard Settings.isLoopback(baseURL), let url = URL(string: baseURL) else { throw OllamaError.notLoopback(baseURL) }
        _baseURL = url
        _model = model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    public var model: String {
        get { lock.lock(); defer { lock.unlock() }; return _model }
        set { lock.lock(); _model = newValue; lock.unlock() }
    }

    public var baseURL: URL {
        get { lock.lock(); defer { lock.unlock() }; return _baseURL }
    }

    /// Refuses anything that isn't loopback.
    public func setBaseURL(_ s: String) throws {
        guard Settings.isLoopback(s), let url = URL(string: s) else { throw OllamaError.notLoopback(s) }
        lock.lock(); _baseURL = url; lock.unlock()
    }

    // MARK: Cleaner

    public func clean(_ raw: String, context: CleanupContext) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "keep_alive": "30m",
            "messages": [
                ["role": "system", "content": Prompts.system(context: context)],
                ["role": "user", "content": Prompts.userMessage(Prompts.exampleRaw)],
                ["role": "assistant", "content": Prompts.exampleCleaned],
                ["role": "user", "content": Prompts.userMessage(raw)],
            ],
            "options": ["temperature": 0, "num_predict": Prompts.maxResponseTokens(rawCharacters: raw.count)],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CleanerUnavailableError("Ollama isn't running")
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.badResponse("no HTTP response") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 404 { throw CleanerUnavailableError("model \(model) not found: \(msg)") }
            throw OllamaError.badResponse("HTTP \(http.statusCode): \(msg)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaError.badResponse("unexpected JSON")
        }
        return content
    }

    // MARK: Availability and pulls

    /// Loads the model into memory (empty prompt, keep_alive) so the first real cleanup isn't a cold start.
    /// Fire-and-forget; failures are ignored.
    public func warmUp() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["model": model, "stream": false, "keep_alive": "30m", "messages": [], "options": ["num_predict": 0]]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
    }

    /// GET /api/tags with a short timeout. Returns the installed model names, or nil if the server is down.
    public func tags(timeoutMs: Int = 500) async -> [String]? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = Double(timeoutMs) / 1000
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// The Settings/menu availability line.
    public func availability() async -> CleanerAvailability {
        guard let tags = await tags() else {
            return CleanerAvailability(available: false, reason: "Ollama isn't running. Install it from ollama.com and run `ollama pull \(model)`.")
        }
        let wanted = model
        let has = tags.contains { $0 == wanted || $0 == wanted + ":latest" || $0.hasPrefix(wanted + ":") && !wanted.contains(":") }
        if has { return CleanerAvailability(available: true, reason: "Ollama found with \(wanted)") }
        return CleanerAvailability(available: false, reason: "Ollama is running but \(wanted) isn't installed. Run `ollama pull \(wanted)`.")
    }

    /// POST /api/pull, streaming progress lines. `progress` gets (status, completed, total).
    public func pull(model name: String, progress: @escaping @Sendable (String, Int64, Int64) -> Void) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        let (bytes, response) = try await session.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaError.badResponse("pull failed") }
        for try await line in bytes.lines {
            guard let d = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw OllamaError.badResponse(err) }
            let status = obj["status"] as? String ?? ""
            let completed = (obj["completed"] as? NSNumber)?.int64Value ?? 0
            let total = (obj["total"] as? NSNumber)?.int64Value ?? 0
            progress(status, completed, total)
        }
    }
}
