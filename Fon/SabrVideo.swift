import Foundation
import Network

/// Видео по SABR в своём плеере (просьба владельца после 1.100: «видео по SABR со своим плеером, где можно настройки
/// применять, и в фоне»). SABR отдаёт видео и звук отдельными дорожками fMP4 (`SabrEngine.streamVideo`); каждая пишется
/// в свой файл, а AVPlayer получает их как HLS с маленького сервера внутри приложения (127.0.0.1): плейлист растёт по
/// мере загрузки (EVENT), сегменты — куски файла (`EXT-X-BYTERANGE`), в конце — `EXT-X-ENDLIST`.
/// Перемотка — в пределах уже скачанного (SABR качает быстрее, чем играет).
final class SabrVideoSession {
    struct Quality: Equatable {
        let itag: Int
        let label: String
        let height: Int
        let width: Int
        let bitrate: Int
        let codecs: String
        let fps: Int
    }

    let id: String
    let quality: Quality
    private let video: FragmentedTrack
    private let audio: FragmentedTrack
    private let lock = NSLock()
    private var finished = false
    private(set) var failure: String?
    private var job: Int?
    private var cancelled = false
    /// Готово к воспроизведению (есть начало обеих дорожек) или ошибка — один раз, на главном потоке.
    var onReady: ((String?) -> Void)?
    private var reported = false
    /// Субтитры: дорожки страницы (+ перевод на русский, если русских нет) и уже скачанные WebVTT.
    private let captions: [(name: String, language: String, url: String)]
    private let duration: Double
    private var subtitles: [Int: String] = [:]

    static let folder: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("sabr-video", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Видео mp4 (H.264 — его AVPlayer играет везде), по одному на качество, лучшее сверху.
    static func qualities(_ source: SabrEngine.Source) -> [Quality] {
        var best: [String: Quality] = [:]
        for format in source.formats {
            guard let itag = format["itag"] as? Int, let mime = format["mimeType"] as? String,
                  mime.hasPrefix("video/mp4"), mime.contains("avc1") else { continue }
            let height = format["height"] as? Int ?? 0
            let fps = format["fps"] as? Int ?? 30
            let label = format["qualityLabel"] as? String ?? "\(height)p"
            let codecs = mime.components(separatedBy: "codecs=\"").dropFirst().first?.components(separatedBy: "\"").first ?? "avc1.4d401f"
            let quality = Quality(itag: itag, label: label, height: height, width: format["width"] as? Int ?? 0,
                                  bitrate: format["bitrate"] as? Int ?? 1_000_000, codecs: codecs, fps: fps)
            if let old = best[label], old.bitrate >= quality.bitrate { continue }
            best[label] = quality
        }
        return best.values.sorted { ($0.height, $0.fps) > ($1.height, $1.fps) }
    }

    /// Ближайшее к сохранённому качеству (не выше), иначе самое низкое.
    static func preferred(in list: [Quality]) -> Quality? {
        let wanted = Settings.sabrVideoHeight
        return list.first { $0.height <= wanted } ?? list.last
    }

    init(source: SabrEngine.Source, quality: Quality) {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        self.id = id
        self.quality = quality
        duration = source.duration
        var list = source.captions.map { (name: $0.name, language: $0.language, url: $0.url) }
        if !source.captions.contains(where: { $0.language.hasPrefix("ru") }),
           let first = source.captions.first(where: { $0.translatable && !$0.url.contains("kind=asr") }) ?? source.captions.first(where: \.translatable) {
            list.append((name: tr("Русский (перевод)"), language: "ru", url: first.url + "&tlang=ru"))
        }
        // Названия в группе должны различаться.
        var seen: [String: Int] = [:]
        captions = list.map { item in
            seen[item.name, default: 0] += 1
            let count = seen[item.name] ?? 1
            return count > 1 ? (name: "\(item.name) \(count)", language: item.language, url: item.url) : item
        }
        Self.removeOld()
        video = FragmentedTrack(file: Self.folder.appendingPathComponent("\(id)-v.mp4"))
        audio = FragmentedTrack(file: Self.folder.appendingPathComponent("\(id)-a.mp4"))
        LocalHLSServer.shared.add(self)
        Task {
            let job = await SabrEngine.shared.streamVideo(source, videoItag: quality.itag, onData: { [weak self] track, data in
                self?.received(track, data)
            }, onDone: { [weak self] error in
                self?.ended(error)
            })
            self.lock.lock()
            self.job = job
            let stop = self.cancelled
            self.lock.unlock()
            if stop { SabrEngine.shared.cancel(job) }
        }
    }

    /// Остановить загрузку и стереть файлы.
    func close() {
        lock.lock()
        cancelled = true
        let job = self.job
        video.close()
        audio.close()
        lock.unlock()
        if let job { SabrEngine.shared.cancel(job) }
        LocalHLSServer.shared.remove(self)
        try? FileManager.default.removeItem(at: video.file)
        try? FileManager.default.removeItem(at: audio.file)
    }

    /// Остатки прошлых сеансов (приложение закрыли посреди видео).
    private static func removeOld() {
        let active = LocalHLSServer.shared.activeIDs
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !active.contains(where: { file.lastPathComponent.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    var masterURL: URL? {
        guard let port = LocalHLSServer.shared.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/\(id)/master.m3u8")
    }

    /// Сколько секунд уже скачано (меньшее из двух дорожек).
    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return min(video.seconds, audio.seconds)
    }

    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    // MARK: - Загрузка (очередь fon.sabr)

    private func received(_ track: Int, _ data: Data) {
        lock.lock()
        (track == 0 ? video : audio).append(data)
        let ready = video.segments.count >= 2 && audio.segments.count >= 1
        lock.unlock()
        if ready { report(nil) }
    }

    private func ended(_ error: String?) {
        lock.lock()
        finished = true
        failure = error
        let usable = !video.segments.isEmpty && !audio.segments.isEmpty
        lock.unlock()
        report(usable ? nil : (error ?? tr("SABR: видео не пришло")))
    }

    private func report(_ error: String?) {
        DispatchQueue.main.async {
            guard !self.reported else { return }
            self.reported = true
            self.onReady?(error)
        }
    }

    // MARK: - Для сервера

    func playlist(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        switch name {
        case "master.m3u8":
            let resolution = quality.width > 0 ? ",RESOLUTION=\(quality.width)x\(quality.height)" : ""
            return """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="a.m3u8"
            \(subtitleMedia)#EXT-X-STREAM-INF:BANDWIDTH=\(quality.bitrate + 140_000),CODECS="\(quality.codecs),mp4a.40.2"\(resolution),FRAME-RATE=\(quality.fps),AUDIO="aud"\(captions.isEmpty || duration <= 0 ? "" : ",SUBTITLES=\"subs\"")
            v.m3u8

            """
        case _ where name.hasPrefix("s"):
            guard let index = Int(name.dropFirst().dropLast(5)), captions.indices.contains(index), duration > 0 else { return nil }
            let length = String(format: "%.3f", duration)
            return "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(duration.rounded(.up)))\n#EXT-X-MEDIA-SEQUENCE:0\n"
                + "#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:\(length),\ns\(index).vtt\n#EXT-X-ENDLIST\n"
        case "v.m3u8": return video.playlist(media: "v.mp4", finished: finished)
        case "a.m3u8": return audio.playlist(media: "a.mp4", finished: finished)
        default: return nil
        }
    }

    /// Строки субтитров для master (под замком).
    private var subtitleMedia: String {
        guard duration > 0 else { return "" }
        return captions.enumerated().map { index, item in
            let name = item.name.replacingOccurrences(of: "\"", with: "'")
            let language = item.language.isEmpty ? "" : ",LANGUAGE=\"\(item.language)\""
            return "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\"\(language),DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI=\"s\(index).m3u8\"\n"
        }.joined()
    }

    /// WebVTT дорожки `s<i>.vtt`: YouTube json3 → свой WebVTT (чище, чем их vtt с «бегущими» строками), не вышло — их vtt.
    /// Не скачалось — пустой WebVTT (плеер не ломается).
    func subtitle(_ name: String, completion: @escaping (String) -> Void) {
        guard name.hasPrefix("s"), name.hasSuffix(".vtt"), let index = Int(name.dropFirst().dropLast(4)) else { return completion(Subtitles.empty) }
        lock.lock()
        let cached = subtitles[index]
        let item = captions.indices.contains(index) ? captions[index] : nil
        lock.unlock()
        if let cached { return completion(cached) }
        guard let item else { return completion(Subtitles.empty) }
        Task {
            let text = await Subtitles.load(item.url)
            self.lock.lock()
            if text != Subtitles.empty { self.subtitles[index] = text }
            self.lock.unlock()
            completion(text)
        }
    }

    func fileFor(_ name: String) -> (url: URL, length: Int)? {
        lock.lock(); defer { lock.unlock() }
        switch name {
        case "v.mp4": return (video.file, video.written)
        case "a.mp4": return (audio.file, audio.written)
        default: return nil
        }
    }
}

/// Дорожка fMP4, которая пишется в файл по кускам: где кончается init (ftyp+moov) и где каждый фрагмент (moof+mdat)
/// с его длительностью (из trun/tfhd/trex и timescale из mdhd).
final class FragmentedTrack {
    struct Segment {
        let offset: Int
        let length: Int
        let duration: Double
    }

    let file: URL
    private var handle: FileHandle?
    private(set) var written = 0
    private(set) var initLength = 0
    private(set) var segments: [Segment] = []
    private(set) var seconds: Double = 0
    private var buffer: [UInt8] = []
    private var bufferOffset = 0
    private var skipping: (type: String, start: Int, size: Int, left: Int)?
    private var segmentStart: Int?
    private var fragmentTicks: UInt64?
    private var timescale: UInt32 = 0
    private var trexDuration: UInt32 = 0

    init(file: URL) {
        self.file = file
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    func append(_ data: Data) {
        guard let handle else { return }
        handle.write(data)
        written += data.count
        buffer.append(contentsOf: data)
        parse()
    }

    private func parse() {
        while true {
            if var skip = skipping {
                let count = min(skip.left, buffer.count)
                buffer.removeFirst(count)
                bufferOffset += count
                skip.left -= count
                if skip.left > 0 { skipping = skip; return }
                skipping = nil
                finished(skip.type, start: skip.start, size: skip.size, body: nil)
                continue
            }
            guard buffer.count >= 8 else { return }
            var size = Int(Self.u32(buffer, 0))
            let type = String(decoding: buffer[4..<8], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard buffer.count >= 16 else { return }
                size = Int(Self.u64(buffer, 8))
                header = 16
            }
            guard size >= header else { buffer.removeAll(); return } // мусор — дальше не разобрать
            if type == "moov" || type == "moof" {
                guard buffer.count >= size else { return }
                let body = Array(buffer[header..<size])
                let start = bufferOffset
                buffer.removeFirst(size)
                bufferOffset += size
                finished(type, start: start, size: size, body: body)
            } else {
                skipping = (type, bufferOffset, size, size)
            }
        }
    }

    private func finished(_ type: String, start: Int, size: Int, body: [UInt8]?) {
        let end = start + size
        switch type {
        case "moov":
            if let body { readMoov(body) }
            if initLength == 0 { initLength = end }
            segmentStart = end
        case "moof":
            if let body { fragmentTicks = readMoof(body) }
        case "mdat":
            guard let begin = segmentStart, let ticks = fragmentTicks else { return }
            let duration = Double(ticks) / Double(timescale > 0 ? timescale : 1000)
            segments.append(Segment(offset: begin, length: end - begin, duration: max(duration, 0.01)))
            seconds += duration
            segmentStart = end
            fragmentTicks = nil
        default:
            break // styp/sidx/emsg — войдут в следующий сегмент
        }
    }

    func playlist(media: String, finished: Bool) -> String? {
        guard initLength > 0 else { return nil }
        let target = max(10, Int((segments.map(\.duration).max() ?? 0).rounded(.up)))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:EVENT", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES",
                     "#EXT-X-MAP:URI=\"\(media)\",BYTERANGE=\"\(initLength)@0\""]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.5f,", segment.duration))
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(media)
        }
        if finished { lines.append("#EXT-X-ENDLIST") } // тип не меняем (EVENT): по правилам HLS он постоянный
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Боксы MP4

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(u32(b, i)) << 32 | UInt64(u32(b, i + 4))
    }

    /// Дочерние боксы: (тип, начало тела, конец).
    private static func children(_ b: [UInt8], _ from: Int, _ to: Int) -> [(String, Int, Int)] {
        var result: [(String, Int, Int)] = []
        var i = from
        while i + 8 <= to {
            var size = Int(u32(b, i))
            var header = 8
            if size == 1 { size = Int(u64(b, i + 8)); header = 16 }
            if size == 0 { size = to - i }
            guard size >= header, i + size <= to else { break }
            result.append((String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self), i + header, i + size))
            i += size
        }
        return result
    }

    private func readMoov(_ b: [UInt8]) {
        for (type, from, to) in Self.children(b, 0, b.count) {
            if type == "trak" {
                for (t2, f2, e2) in Self.children(b, from, to) where t2 == "mdia" {
                    for (t3, f3, _) in Self.children(b, f2, e2) where t3 == "mdhd" {
                        let version = b[f3]
                        timescale = Self.u32(b, f3 + (version == 1 ? 20 : 12))
                    }
                }
            } else if type == "mvex" {
                for (t2, f2, _) in Self.children(b, from, to) where t2 == "trex" {
                    trexDuration = Self.u32(b, f2 + 12)
                }
            }
        }
    }

    /// Длительность фрагмента в единицах timescale.
    private func readMoof(_ b: [UInt8]) -> UInt64 {
        var total: UInt64 = 0
        for (type, from, to) in Self.children(b, 0, b.count) where type == "traf" {
            var defaultDuration = trexDuration
            for (t2, f2, _) in Self.children(b, from, to) {
                if t2 == "tfhd" {
                    let flags = Self.u32(b, f2) & 0xFFFFFF
                    var i = f2 + 8
                    if flags & 0x01 != 0 { i += 8 }
                    if flags & 0x02 != 0 { i += 4 }
                    if flags & 0x08 != 0 { defaultDuration = Self.u32(b, i) }
                } else if t2 == "trun" {
                    let flags = Self.u32(b, f2) & 0xFFFFFF
                    let count = Int(Self.u32(b, f2 + 4))
                    var i = f2 + 8
                    if flags & 0x01 != 0 { i += 4 }
                    if flags & 0x04 != 0 { i += 4 }
                    guard flags & 0x100 != 0 else { total += UInt64(defaultDuration) * UInt64(count); continue }
                    var stride = 4
                    if flags & 0x200 != 0 { stride += 4 }
                    if flags & 0x400 != 0 { stride += 4 }
                    if flags & 0x800 != 0 { stride += 4 }
                    for n in 0..<count { total += UInt64(Self.u32(b, i + n * stride)) }
                }
            }
        }
        return total
    }
}

/// Маленький HTTP-сервер на 127.0.0.1 для AVPlayer: плейлисты и куски файлов сеансов `SabrVideoSession`.
final class LocalHLSServer {
    static let shared = LocalHLSServer()

    private let queue = DispatchQueue(label: "fon.hls", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [String: SabrVideoSession] = [:]
    private let lock = NSLock()
    private var currentPort: UInt16?

    var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return currentPort
    }

    var activeIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.keys)
    }

    func add(_ session: SabrVideoSession) {
        lock.lock()
        sessions[session.id] = session
        lock.unlock()
    }

    func remove(_ session: SabrVideoSession) {
        lock.lock()
        sessions[session.id] = nil
        lock.unlock()
    }

    /// Запустить (или убедиться, что работает). Возвращает порт.
    func start() async -> UInt16? {
        if let port { return port }
        return await withCheckedContinuation { continuation in
            queue.async {
                let parameters = NWParameters.tcp
                parameters.requiredInterfaceType = .loopback
                parameters.acceptLocalOnly = true
                guard let listener = try? NWListener(using: parameters, on: .any) else { return continuation.resume(returning: nil) }
                var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.lock.lock()
                        self.currentPort = listener.port?.rawValue
                        self.lock.unlock()
                        if !resumed { resumed = true; continuation.resume(returning: listener.port?.rawValue) }
                    case .failed, .cancelled:
                        self.lock.lock()
                        if self.listener === listener { self.currentPort = nil; self.listener = nil }
                        self.lock.unlock()
                        if !resumed { resumed = true; continuation.resume(returning: nil) }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                self.lock.lock()
                self.listener = listener
                self.lock.unlock()
                listener.start(queue: self.queue)
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || complete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        guard parts.count >= 2 else { return send(connection, status: "400 Bad Request", type: "text/plain", body: Data()) }
        let method = parts[0]
        let path = parts[1].components(separatedBy: "?")[0].split(separator: "/").map(String.init)
        lock.lock()
        let session = path.count == 2 ? sessions[path[0]] : nil
        lock.unlock()
        guard let session, path.count == 2 else { return send(connection, status: "404 Not Found", type: "text/plain", body: Data()) }
        let name = path[1]
        if name.hasSuffix(".vtt") {
            return session.subtitle(name) { text in
                self.queue.async { self.send(connection, status: "200 OK", type: "text/vtt", body: Data(text.utf8), head: method == "HEAD") }
            }
        }
        if name.hasSuffix(".m3u8") {
            guard let text = session.playlist(name) else { return send(connection, status: "404 Not Found", type: "text/plain", body: Data()) }
            return send(connection, status: "200 OK", type: "application/vnd.apple.mpegurl", body: Data(text.utf8), head: method == "HEAD")
        }
        guard let file = session.fileFor(name) else { return send(connection, status: "404 Not Found", type: "text/plain", body: Data()) }
        let type = name.hasPrefix("a") ? "audio/mp4" : "video/mp4"
        var from = 0
        var to = file.length - 1
        var partial = false
        if let range = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = range.components(separatedBy: "=").last {
            let bounds = spec.trimmingCharacters(in: .whitespaces).components(separatedBy: "-")
            if let a = Int(bounds[0]) { from = a }
            if bounds.count > 1, let b = Int(bounds[1]) { to = min(b, file.length - 1) }
            partial = true
        }
        guard from <= to, from < file.length else {
            return send(connection, status: "416 Range Not Satisfiable", type: type, body: Data(), extra: ["Content-Range: bytes */\(file.length)"])
        }
        var body = Data()
        if method != "HEAD", let reader = try? FileHandle(forReadingFrom: file.url) {
            try? reader.seek(toOffset: UInt64(from))
            body = (try? reader.read(upToCount: to - from + 1)) ?? Data()
            try? reader.close()
        }
        let last = method == "HEAD" ? to : from + body.count - 1
        let extra = partial ? ["Content-Range: bytes \(from)-\(last)/\(file.length)"] : []
        send(connection, status: partial ? "206 Partial Content" : "200 OK", type: type, body: body, head: method == "HEAD",
             length: method == "HEAD" ? to - from + 1 : nil, extra: extra)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, head: Bool = false,
                      length: Int? = nil, extra: [String] = []) {
        var header = ["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(length ?? body.count)",
                      "Accept-Ranges: bytes", "Cache-Control: no-cache", "Connection: close"] + extra
        header.append("")
        header.append("")
        var data = Data(header.joined(separator: "\r\n").utf8)
        if !head { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Субтитры YouTube (timedtext) → WebVTT для HLS.
enum Subtitles {
    static let empty = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"

    static func load(_ base: String) async -> String {
        if let data = await fetch(base + "&fmt=json3"), let text = fromJSON3(data) { return text }
        if let data = await fetch(base + "&fmt=vtt"), var text = String(data: data, encoding: .utf8), text.hasPrefix("WEBVTT") {
            if !text.contains("X-TIMESTAMP-MAP") {
                let end = text.firstIndex(of: "\n") ?? text.endIndex
                text.insert(contentsOf: "\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000", at: end)
            }
            return text
        }
        return empty
    }

    private static func fetch(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(YouTubeStreams.iPhoneSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    /// json3: events[] с tStartMs, dDurationMs и segs[].utf8.
    static func fromJSON3(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { return nil }
        var lines = [empty]
        var count = 0
        for event in events {
            guard let segments = event["segs"] as? [[String: Any]], let start = event["tStartMs"] as? Double else { continue }
            let text = segments.compactMap { $0["utf8"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let length = event["dDurationMs"] as? Double ?? 2000
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            lines.append("\(stamp(start)) --> \(stamp(start + max(length, 300)))\n\(escaped)\n\n")
            count += 1
        }
        return count > 0 ? lines.joined() : nil
    }

    private static func stamp(_ ms: Double) -> String {
        let total = Int(ms.rounded())
        return String(format: "%02d:%02d:%02d.%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }
}
