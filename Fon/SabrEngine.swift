import JavaScriptCore
import UIKit

/// Звук по SABR — для устройств, которым YouTube не даёт обычных ссылок (iPad, iPhone 17; владелец после 1.98).
/// Проба 1.99 на iPhone владельца: защита потока 1 (без PO-токена), весь трек itag 140 (~3,3 МБ) за 3 с,
/// системный плеер его играет. Протокол ведёт библиотека googlevideo (MIT, `Solver/googlevideo.sabr.min.txt`)
/// **внутри приложения**, в JavaScriptCore — не в скрытом окне: процесс WebKit iOS усыпляет в фоне, а этот — нет
/// (владелец: «второй вариант сразу»). Недостающие браузерные функции (URL, потоки, таймеры, TextDecoder…) —
/// `Solver/sabr.runtime.txt`; таймеры и запросы к googlevideo делает Swift. Трек качается целиком в файл
/// (`Caches/sabr/<id>.m4a`), потом его играет AVPlayer — как скачанный.
final class SabrEngine {
    static let shared = SabrEngine()

    /// Всё, что нужно для потока, со страницы видео (`DirectStream`).
    struct Source {
        let videoID: String
        var url: String
        let config: String
        let clientName: Int
        let clientVersion: String
        let formats: [[String: Any]]
        let playerURL: URL?
        /// Субтитры со страницы (для своего видеоплеера) и длина видео.
        var captions: [Caption] = []
        var duration: Double = 0
        /// Привязка PO-токена (DATASYNC_ID со входом, VISITOR_DATA без) — `PoToken`.
        var poBinding: String?
        var poToken: String?
    }

    struct Caption {
        let url: String
        let name: String
        let language: String
        let translatable: Bool
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private struct Job {
        let handle: FileHandle
        let temp: URL
        let file: URL
        var bytes = 0
        let finish: (Result<URL, Error>) -> Void
    }

    private let queue = DispatchQueue(label: "fon.sabr", qos: .userInitiated)
    private var context: JSContext?
    private var jobs: [Int: Job] = [:]
    /// Видео для своего видеоплеера (`SabrVideo`): куски дорожек отдаются сразу, на очереди `fon.sabr`.
    private struct VideoJob {
        let onData: (Int, Data) -> Void
        let onDone: (String?) -> Void
    }
    private var videoJobs: [Int: VideoJob] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextID = 1
    private var lastException: String?
    /// Итог последней загрузки звука — для диагностики (⚙ → «Диагностика системного плеера»).
    private var report = ""
    /// Был ли PO-токен у последней загрузки (пишется до старта, читается в отчёте).
    private var poNote = ""
    var lastReport: String { queue.sync { report } }

    static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sabr", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Уже скачанный по SABR трек (файл живёт, пока его не вытеснят новые — `cleanUp`).
    static func cached(_ videoID: String) -> URL? {
        let file = folder.appendingPathComponent(videoID + ".m4a")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 10_000 else { return nil }
        return file
    }

    /// Трек целиком в файл. n в адресе — решателем (как у обычных ссылок).
    /// `usePoToken: false` — без PO-токена (диагностика: сравнить «с токеном» и «без»).
    func download(_ source: Source, usePoToken: Bool = true, timeout: Double = 90) async throws -> URL {
        if let file = Self.cached(source.videoID) { return file }
        let source = await solved(source, usePoToken: usePoToken)
        Self.cleanUp()
        let file = Self.folder.appendingPathComponent(source.videoID + ".m4a")
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.start(source, file: file, timeout: timeout) { continuation.resume(with: $0) } }
        }
    }

    /// Видео + звук двумя дорожками fMP4 (`SabrVideo`). onData(0 — видео / 1 — звук, байты), onDone(nil — всё пришло,
    /// иначе причина). Вызовы — на своей очереди. Возвращает номер для `cancel`.
    func streamVideo(_ source: Source, videoItag: Int, audioTrack: String? = nil, onData: @escaping (Int, Data) -> Void, onDone: @escaping (String?) -> Void) async -> Int {
        let source = await solved(source)
        return await withCheckedContinuation { continuation in
            queue.async {
                let id = self.nextID
                self.nextID += 1
                continuation.resume(returning: id)
                guard let context = self.prepareContext() else { return onDone("SABR: движок не запустился (\(self.lastException ?? "?"))") }
                self.videoJobs[id] = VideoJob(onData: onData, onDone: onDone)
                let job: [String: Any] = ["id": id, "videoId": source.videoID, "url": source.url, "config": source.config, "clientName": source.clientName,
                                          "clientVersion": source.clientVersion, "videoItag": videoItag, "audioTrackId": audioTrack ?? "", "formats": source.formats,
                                          "poToken": source.poToken ?? ""]
                guard let data = try? JSONSerialization.data(withJSONObject: job), let json = String(data: data, encoding: .utf8) else {
                    return self.complete(id, error: "SABR: форматы не разобрались", info: "")
                }
                context.evaluateScript("__fonSabrVideo(\(json))")
            }
        }
    }

    func cancel(_ id: Int) {
        queue.async {
            guard self.videoJobs.removeValue(forKey: id) != nil else { return }
            self.context?.evaluateScript("__fonSabrCancel(\(id))")
        }
    }

    /// n в адресе — решателем (как у обычных ссылок).
    private func solved(_ source: Source, usePoToken: Bool = true) async -> Source {
        var source = source
        if !usePoToken {
            queue.sync { poNote = "PO-токен: не использован (проба без него)" }
        } else if let binding = source.poBinding, !binding.isEmpty {
            source.poToken = await Self.poToken(for: binding)
            let detail = PoToken.cached(for: binding) != nil && source.poToken != nil ? await PoToken.shared.lastReport : "в фоне — только готовый"
            let note = source.poToken != nil ? "PO-токен: есть (\(detail))" : "PO-токен: нет (\(await PoToken.shared.lastReport))"
            queue.sync { poNote = note }
        } else {
            queue.sync { poNote = "PO-токен: нет привязки" }
        }
        if var parts = URLComponents(string: source.url), let n = parts.queryItems?.first(where: { $0.name == "n" })?.value,
           let playerURL = source.playerURL,
           let answer = try? await ChallengeSolver.shared.solve(playerURL: playerURL, n: [n], signatures: []), let value = answer.n[n] {
            parts.queryItems = parts.queryItems?.map { $0.name == "n" ? URLQueryItem(name: "n", value: value) : $0 }
            source.url = parts.url?.absoluteString ?? source.url
        }
        return source
    }

    /// PO-токен: в фоне — только готовый (скрытое окно там может не ответить), на экране — получить.
    static func poToken(for binding: String) async -> String? {
        if let token = PoToken.cached(for: binding) { return token }
        let active = await MainActor.run { UIApplication.shared.applicationState != .background }
        guard active else { return nil }
        PoToken.rememberBinding(binding)
        return await PoToken.shared.token(for: binding)
    }

    // MARK: - На своей очереди

    private func start(_ source: Source, file: URL, timeout: Double, finish: @escaping (Result<URL, Error>) -> Void) {
        guard let context = prepareContext() else { return finish(.failure(Failure.message("SABR: движок не запустился (\(lastException ?? "?"))"))) }
        let id = nextID
        nextID += 1
        let temp = file.appendingPathExtension("part")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return finish(.failure(Failure.message("SABR: нет места для файла"))) }
        jobs[id] = Job(handle: handle, temp: temp, file: file, finish: finish)
        let job: [String: Any] = ["id": id, "videoId": source.videoID, "url": source.url, "config": source.config, "clientName": source.clientName,
                                  "clientVersion": source.clientVersion, "itag": 140, "formats": source.formats,
                                  "poToken": source.poToken ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: job), let json = String(data: data, encoding: .utf8) else {
            return complete(id, error: "SABR: форматы не разобрались", info: "")
        }
        context.evaluateScript("__fonSabrDownload(\(json))")
        // Обычно трек приходит за секунды; повис — не ждём вечно.
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.jobs[id] != nil else { return }
            context.evaluateScript("__fonSabrCancel(\(id))")
            self.complete(id, error: "SABR: слишком долго", info: "")
        }
    }

    private func complete(_ id: Int, error: String, info: String) {
        if let video = videoJobs.removeValue(forKey: id) {
            let log = ((try? JSONSerialization.jsonObject(with: Data(info.utf8))) as? [String: Any])?["log"] as? [String] ?? []
            guard !error.isEmpty else { return video.onDone(nil) }
            return video.onDone(([error.hasPrefix("SABR") ? error : "SABR: " + error] + log.prefix(3)).joined(separator: "; "))
        }
        guard let job = jobs.removeValue(forKey: id) else { return }
        try? job.handle.close()
        let parsed = (try? JSONSerialization.jsonObject(with: Data(info.utf8))) as? [String: Any]
        // По частям: одним выражением компилятор не успевал разобрать типы (сборка 1.106 упала).
        let requests: Int = parsed?["requests"] as? Int ?? 0
        let log: [String] = parsed?["log"] as? [String] ?? []
        var parts: [String] = ["запросов \(requests), байт \(job.bytes)"]
        if !error.isEmpty { parts.append("ошибка: \(error)") }
        if !log.isEmpty { parts.append("журнал: " + log.prefix(30).joined(separator: " | ")) }
        if let exception = lastException { parts.append("JS: " + String(exception.prefix(120))) }
        if !poNote.isEmpty { parts.append(poNote) }
        report = parts.joined(separator: "; ")
        AppJournal.add("SABR звук: " + (error.isEmpty ? "готово" : error) + "; " + report)
        if error.isEmpty, job.bytes > 10_000 {
            // Длина в moov YouTube + длина фрагментов — AVPlayer показывал двойную длину (iPad, 1.104: 406 с при 203).
            if let note = Self.zeroMoovDurations(job.temp) { report += "; moov: " + note }
            try? FileManager.default.removeItem(at: job.file)
            do {
                try FileManager.default.moveItem(at: job.temp, to: job.file)
                job.finish(.success(job.file))
            } catch {
                job.finish(.failure(error))
            }
        } else {
            try? FileManager.default.removeItem(at: job.temp)
            let log = ((try? JSONSerialization.jsonObject(with: Data(info.utf8))) as? [String: Any])?["log"] as? [String] ?? []
            let text = error.isEmpty ? "SABR: звук не пришёл (\(job.bytes) байт)" : (error.hasPrefix("SABR") ? error : "SABR: " + error)
            job.finish(.failure(Failure.message(([text] + log.prefix(3)).joined(separator: "; "))))
        }
    }

    /// Обнуляет длительности в moov фрагментированного файла (mvhd, tkhd, mdhd, mehd): тогда длина трека —
    /// только сумма фрагментов. Возвращает, что было (для диагностики), или nil, если moov не нашёлся.
    static func zeroMoovDurations(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: 512 * 1024), data.count > 16 else { return nil }
        func u32(_ o: Int) -> Int { data[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
        func u64(_ o: Int) -> Int { data[o..<o + 8].reduce(0) { $0 << 8 | Int($1) } }
        func zero(_ o: Int, _ n: Int) { for i in o..<o + n { data[i] = 0 } }
        var notes: [String] = []
        var movieScale = 0
        /// Обходит боксы в [start, end); для контейнеров — внутрь.
        func walk(_ start: Int, _ end: Int) {
            var o = start
            while o + 8 <= end {
                var size = u32(o)
                let type = String(decoding: data[o + 4..<o + 8], as: UTF8.self)
                var header = 8
                if size == 1, o + 16 <= end { size = u64(o + 8); header = 16 }
                if size == 0 { size = end - o }
                guard size >= header, o + size <= end else { return }
                let body = o + header
                let v1 = body < data.count && data[body] == 1
                switch type {
                case "moov", "trak", "mdia", "mvex":
                    walk(body, o + size)
                case "mvhd" where o + size >= body + (v1 ? 32 : 20):
                    movieScale = v1 ? u32(body + 20) : u32(body + 12)
                    let d = v1 ? u64(body + 24) : u32(body + 16)
                    notes.append("mvhd \(movieScale > 0 ? "\(d / movieScale) с" : "\(d)")")
                    zero(v1 ? body + 24 : body + 16, v1 ? 8 : 4)
                case "tkhd" where o + size >= body + (v1 ? 36 : 24):
                    let d = v1 ? u64(body + 28) : u32(body + 20)
                    notes.append("tkhd \(movieScale > 0 ? "\(d / movieScale) с" : "\(d)")")
                    zero(v1 ? body + 28 : body + 20, v1 ? 8 : 4)
                case "mdhd" where o + size >= body + (v1 ? 32 : 20):
                    let scale = v1 ? u32(body + 20) : u32(body + 12)
                    let d = v1 ? u64(body + 24) : u32(body + 16)
                    notes.append("mdhd \(scale > 0 ? "\(d / scale) с" : "\(d)")")
                    zero(v1 ? body + 24 : body + 16, v1 ? 8 : 4)
                case "mehd" where o + size >= body + (v1 ? 12 : 8):
                    let d = v1 ? u64(body + 4) : u32(body + 4)
                    notes.append("mehd \(movieScale > 0 ? "\(d / movieScale) с" : "\(d)")")
                    zero(body + 4, v1 ? 8 : 4)
                default:
                    break
                }
                o += size
            }
        }
        // moov ищем только на верхнем уровне (ftyp, moov, затем фрагменты).
        var o = 0
        while o + 8 <= data.count {
            var size = u32(o)
            let type = String(decoding: data[o + 4..<o + 8], as: UTF8.self)
            if size == 1, o + 16 <= data.count { size = u64(o + 8) }
            guard size >= 8 else { return nil }
            if type == "moov" {
                guard o + size <= data.count else { return nil }
                walk(o, o + size)
                guard !notes.isEmpty else { return "без длительностей" }
                do {
                    try handle.seek(toOffset: UInt64(o))
                    try handle.write(contentsOf: data[o..<o + size])
                } catch { return "не записалось" }
                return notes.joined(separator: ", ") + " → 0"
            }
            o += size
        }
        return nil
    }

    private func prepareContext() -> JSContext? {
        if let context { return context }
        guard let library = Self.text("googlevideo.sabr.min"), let runtime = Self.text("sabr.runtime"),
              let context = JSContext() else { lastException = "нет файлов библиотеки"; return nil }
        context.exceptionHandler = { [weak self] _, value in self?.lastException = value?.toString() }
        let native = JSValue(newObjectIn: context)
        let timer: @convention(block) (Int, Double) -> Void = { [weak self] id, ms in self?.schedule(id, ms: ms) }
        let cancel: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
        let fetch: @convention(block) (Int, String, String, String, String) -> Void = { [weak self] id, url, method, headers, body in
            self?.fetch(id, url: url, method: method, headers: headers, body: body)
        }
        let chunk: @convention(block) (Int, String) -> Void = { [weak self] id, base64 in
            guard let self, var job = self.jobs[id], let data = Data(base64Encoded: base64) else { return }
            job.handle.write(data)
            job.bytes += data.count
            self.jobs[id] = job
        }
        // Куски видео — Uint8Array без base64 (в JavaScriptCore приложения нет JIT — перекодирование дорогое).
        let media: @convention(block) (Int, Int, JSValue) -> Void = { [weak self] id, track, value in
            guard let self, let job = self.videoJobs[id], let ref = value.context?.jsGlobalContextRef,
                  let object = JSValueToObject(ref, value.jsValueRef, nil) else { return }
            let length = JSObjectGetTypedArrayByteLength(ref, object, nil)
            guard length > 0, let bytes = JSObjectGetTypedArrayBytesPtr(ref, object, nil) else { return }
            job.onData(track, Data(bytes: bytes, count: length))
        }
        let done: @convention(block) (Int, String, String) -> Void = { [weak self] id, error, info in self?.complete(id, error: error, info: info) }
        native?.setObject(timer, forKeyedSubscript: "timer" as NSString)
        native?.setObject(cancel, forKeyedSubscript: "cancel" as NSString)
        native?.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        native?.setObject(chunk, forKeyedSubscript: "chunk" as NSString)
        native?.setObject(done, forKeyedSubscript: "done" as NSString)
        native?.setObject(media, forKeyedSubscript: "media" as NSString)
        context.setObject(native, forKeyedSubscript: "__fonNative" as NSString)
        lastException = nil
        context.evaluateScript(runtime) // окружение и запуск (FonSabr нужен только при вызове)
        context.evaluateScript(library + "\n;globalThis.FonSabr = FonSabr;")
        guard lastException == nil, context.objectForKeyedSubscript("__fonSabrDownload")?.isObject == true else { return nil }
        self.context = context
        return context
    }

    private func schedule(_ id: Int, ms: Double) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.timers.removeValue(forKey: id) != nil else { return }
            self.context?.evaluateScript("__fonFire(\(id))")
        }
        timers[id] = item
        queue.asyncAfter(deadline: .now() + ms / 1000, execute: item)
    }

    /// Запрос библиотеки к googlevideo — ответ целиком (по сети ~300 КБ за запрос).
    private func fetch(_ id: Int, url: String, method: String, headers: String, body: String) {
        guard let address = URL(string: url) else { return reply(id, status: 0, type: "", body: Data(), error: "плохой адрес") }
        var request = URLRequest(url: address, timeoutInterval: 30)
        request.httpMethod = method
        ((try? JSONSerialization.jsonObject(with: Data(headers.utf8))) as? [String: String])?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        if !body.isEmpty { request.httpBody = Data(base64Encoded: body) }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            self?.queue.async {
                self?.reply(id, status: http?.statusCode ?? 0, type: http?.value(forHTTPHeaderField: "Content-Type") ?? "",
                            body: data ?? Data(), error: error?.localizedDescription ?? "")
            }
        }.resume()
    }

    /// Ответ — готовым Uint8Array (байты кладутся напрямую), не base64: видео — десятки МБ.
    private func reply(_ id: Int, status: Int, type: String, body: Data, error: String) {
        guard let context, let ref = context.jsGlobalContextRef else { return }
        var payload: Any = ""
        if !body.isEmpty {
            if let array = JSObjectMakeTypedArray(ref, kJSTypedArrayTypeUint8Array, body.count, nil),
               let bytes = JSObjectGetTypedArrayBytesPtr(ref, array, nil), let value = JSValue(jsValueRef: array, in: context) {
                body.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: body.count)
                payload = value
            } else {
                payload = body.base64EncodedString()
            }
        }
        context.objectForKeyedSubscript("__fonFetchDone")?.call(withArguments: [id, status, type, payload, error])
    }

    private static func text(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// Держим последние 40 треков (~130 МБ) — свежие нужны для «назад» и повтора.
    private static func cleanUp() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        sorted.dropFirst(40).forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
