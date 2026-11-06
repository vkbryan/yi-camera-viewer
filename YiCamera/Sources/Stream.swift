// Native RTSP (over TCP) client + H.264 depacketizer + VideoToolbox decoder.
// No third-party dependencies.

import Foundation
import VideoToolbox
import CoreMedia
import CryptoKit

struct StreamError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Socket

final class TCPSocket {
    private var fd: Int32 = -1
    private var buffer = [UInt8]()
    private var start = 0
    private var chunk = [UInt8](repeating: 0, count: 65536)

    init(host: String, port: Int, timeout: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw StreamError("Can't find a camera at \(host).")
        }
        defer { freeaddrinfo(list) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                if TCPSocket.connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout) { fd = s; break }
                Darwin.close(s)
            }
            ai = a.pointee.ai_next
        }
        guard fd >= 0 else {
            throw StreamError("Couldn't reach the camera at \(host). Check that it's powered on and the IP address is right.")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connect(_ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: socklen_t, _ timeout: Int) -> Bool {
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        if Darwin.connect(s, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
        var err: Int32 = 0
        var l = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l)
        return err == 0
    }

    /// Unblocks a pending read from another thread.
    func interrupt() { if fd >= 0 { shutdown(fd, SHUT_RDWR) } }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }

    func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { throw StreamError("Lost connection to the camera.") }
            sent += n
        }
    }

    private func fill() throws {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true); start = 0
        } else if start > 1 << 20 {
            buffer.removeFirst(start); start = 0
        }
        let n = recv(fd, &chunk, chunk.count, 0)
        if n <= 0 { throw StreamError("The camera stopped sending video.") }
        buffer.append(contentsOf: chunk[0..<n])
    }

    private func ensure(_ n: Int) throws {
        while buffer.count - start < n { try fill() }
    }

    func peekByte() throws -> UInt8 {
        try ensure(1)
        return buffer[start]
    }

    func read(_ n: Int) throws -> [UInt8] {
        try ensure(n)
        let out = Array(buffer[start..<start + n])
        start += n
        return out
    }

    /// Reads up to and including the blank line that ends an RTSP header block.
    func readHeaderBlock() throws -> String {
        var scanned = start
        while true {
            if buffer.count >= 4 {
                var i = max(scanned, start)
                while i + 3 < buffer.count {
                    if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
                        let text = String(decoding: buffer[start..<i], as: UTF8.self)
                        start = i + 4
                        return text
                    }
                    i += 1
                }
                scanned = max(start, buffer.count - 3)
            }
            if buffer.count - start > 65536 { throw StreamError("The camera sent an unexpected reply.") }
            try fill()
        }
    }
}

// MARK: - RTSP

struct RTSPResponse {
    var status: Int
    var headers: [String: String]
    var body: String
}

/// HTTP-style Basic/Digest authentication for RTSP.
struct RTSPAuth {
    let username: String
    let password: String
    var digest = false
    var realm = ""
    var nonce = ""
    var opaque: String?
    var qopAuth = false
    var nc = 0

    init?(username: String, password: String, challenge: String) {
        self.username = username
        self.password = password
        let lines = challenge.components(separatedBy: "\n")
        if let d = lines.first(where: { $0.lowercased().hasPrefix("digest") }) {
            digest = true
            let params = RTSPAuth.parse(String(d.dropFirst(6)))
            realm = params["realm"] ?? ""
            nonce = params["nonce"] ?? ""
            opaque = params["opaque"]
            qopAuth = (params["qop"] ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "auth" }
        } else if !lines.contains(where: { $0.lowercased().hasPrefix("basic") }) {
            return nil
        }
    }

    private static func parse(_ s: String) -> [String: String] {
        var out = [String: String]()
        let regex = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]*))"#)
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let k = Range(m.range(at: 1), in: s) else { continue }
            let v = Range(m.range(at: 2), in: s) ?? Range(m.range(at: 3), in: s)
            out[s[k].lowercased()] = v.map { String(s[$0]) } ?? ""
        }
        return out
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    mutating func header(method: String, uri: String) -> String {
        guard digest else {
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
        let ha1 = RTSPAuth.md5("\(username):\(realm):\(password)")
        let ha2 = RTSPAuth.md5("\(method):\(uri)")
        var h = "Digest username=\"\(username)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\""
        if qopAuth {
            nc += 1
            let ncs = String(format: "%08x", nc)
            let cnonce = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            h += ", qop=auth, nc=\(ncs), cnonce=\"\(cnonce)\", response=\"\(RTSPAuth.md5("\(ha1):\(nonce):\(ncs):\(cnonce):auth:\(ha2)"))\""
        } else {
            h += ", response=\"\(RTSPAuth.md5("\(ha1):\(nonce):\(ha2)"))\""
        }
        if let opaque { h += ", opaque=\"\(opaque)\"" }
        return h
    }
}

final class RTSPClient {
    private let socket: TCPSocket
    private let url: String
    private let username: String
    private let password: String
    private var cseq = 0
    private var session: String?
    private var auth: RTSPAuth?

    init(socket: TCPSocket, url: String, username: String, password: String) {
        self.socket = socket
        self.url = url
        self.username = username
        self.password = password
    }

    /// Negotiates the session and then delivers RTP packets from the video channel until an error occurs.
    func play(sprops: (([UInt8], [UInt8])?) -> Void, isCancelled: () -> Bool, packet: ([UInt8]) -> Void) throws {
        _ = try request("OPTIONS", url)
        let describe = try request("DESCRIBE", url, ["Accept": "application/sdp"])
        let sdp = SDP(describe.body)
        guard sdp.hasVideo else { throw StreamError("The camera didn't offer a video stream.") }
        sprops(sdp.parameterSets)

        var base = describe.headers["content-base"] ?? describe.headers["content-location"] ?? url
        if !base.hasSuffix("/") { base += "/" }
        let track: String
        switch sdp.control {
        case nil, "*": track = url
        case let c? where c.lowercased().hasPrefix("rtsp://"): track = c
        case let c?: track = base + c
        }

        let setup = try request("SETUP", track, ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"])
        guard let s = setup.headers["session"] else { throw StreamError("The camera didn't start a session.") }
        session = s.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
        _ = try request("PLAY", url, ["Range": "npt=0.000-"])

        var lastKeepalive = Date()
        while !isCancelled() {
            if try socket.peekByte() == 0x24 { // '$' interleaved binary frame
                let h = try socket.read(4)
                let payload = try socket.read(Int(h[2]) << 8 | Int(h[3]))
                if h[1] == 0 { packet(payload) }
            } else {
                _ = try readResponse() // keep-alive replies
            }
            if Date().timeIntervalSince(lastKeepalive) > 25 {
                try send("GET_PARAMETER", url)
                lastKeepalive = Date()
            }
        }
    }

    private func send(_ method: String, _ uri: String, _ extra: [String: String] = [:]) throws {
        cseq += 1
        var lines = ["\(method) \(uri) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: YiCamera/1.0"]
        if let session { lines.append("Session: \(session)") }
        if auth != nil { lines.append("Authorization: \(auth!.header(method: method, uri: uri))") }
        for (k, v) in extra { lines.append("\(k): \(v)") }
        try socket.write(lines.joined(separator: "\r\n") + "\r\n\r\n")
    }

    private func request(_ method: String, _ uri: String, _ extra: [String: String] = [:]) throws -> RTSPResponse {
        var retried = false
        while true {
            try send(method, uri, extra)
            var r = try readResponse()
            while r.status == -1 { r = try readResponse() } // skipped an interleaved frame
            if r.status == 401 {
                if username.isEmpty {
                    throw StreamError("The camera needs a username and password. Add them in Settings.")
                }
                if retried || auth != nil && !(r.headers["www-authenticate"] ?? "").lowercased().contains("stale=true") {
                    throw StreamError("The camera rejected the username or password.")
                }
                guard let a = RTSPAuth(username: username, password: password, challenge: r.headers["www-authenticate"] ?? "") else {
                    throw StreamError("The camera asked for an unsupported login method.")
                }
                auth = a
                retried = true
                continue
            }
            guard r.status == 200 else { throw StreamError("The camera refused the stream (\(method) → \(r.status)).") }
            return r
        }
    }

    /// Reads one RTSP response. Returns status -1 if an interleaved frame was skipped instead.
    private func readResponse() throws -> RTSPResponse {
        if try socket.peekByte() == 0x24 {
            let h = try socket.read(4)
            _ = try socket.read(Int(h[2]) << 8 | Int(h[3]))
            return RTSPResponse(status: -1, headers: [:], body: "")
        }
        let block = try socket.readHeaderBlock()
        var lines = block.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("RTSP/"), let status = Int(statusLine[1]) else {
            throw StreamError("This doesn't look like a yi-hack camera stream. Is RTSP turned on?")
        }
        var headers = [String: String]()
        for line in lines {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            headers[k] = headers[k].map { $0 + "\n" + v } ?? v
        }
        var body = ""
        if let len = Int(headers["content-length"] ?? ""), len > 0 {
            body = String(decoding: try socket.read(len), as: UTF8.self)
        }
        return RTSPResponse(status: status, headers: headers, body: body)
    }
}

struct SDP {
    var hasVideo = false
    var control: String?
    var parameterSets: ([UInt8], [UInt8])?

    init(_ text: String) {
        var inVideo = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                inVideo = line.hasPrefix("m=video")
                hasVideo = hasVideo || inVideo
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10))
            } else if line.hasPrefix("a=fmtp:"), let r = line.range(of: "sprop-parameter-sets=") {
                let value = line[r.upperBound...].prefix { $0 != ";" }
                let sets = value.split(separator: ",").compactMap { SDP.base64($0) }
                if sets.count >= 2 { parameterSets = (sets[0], sets[1]) }
            }
        }
    }

    private static func base64(_ s: Substring) -> [UInt8]? {
        var str = String(s)
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str).map { [UInt8]($0) }
    }
}

// MARK: - H.264 RTP depacketizer (RFC 6184)

final class H264Depacketizer {
    var onAccessUnit: ([[UInt8]]) -> Void = { _ in }
    private var nals = [[UInt8]]()
    private var fragment: [UInt8]?
    private var timestamp: UInt32?
    private var lastSeq: UInt16?

    func handle(_ p: [UInt8]) {
        guard p.count > 12, p[0] >> 6 == 2 else { return }
        let marker = p[1] & 0x80 != 0
        let seq = UInt16(p[2]) << 8 | UInt16(p[3])
        let ts = UInt32(p[4]) << 24 | UInt32(p[5]) << 16 | UInt32(p[6]) << 8 | UInt32(p[7])
        var offset = 12 + 4 * Int(p[0] & 0x0f)
        if p[0] & 0x10 != 0 {
            guard p.count >= offset + 4 else { return }
            offset += 4 + (Int(p[offset + 2]) << 8 | Int(p[offset + 3])) * 4
        }
        var end = p.count
        if p[0] & 0x20 != 0 { end -= Int(p[end - 1]) }
        guard offset < end else { return }

        if let last = lastSeq, seq != last &+ 1 { fragment = nil } // packet lost mid-fragment
        lastSeq = seq
        if let t = timestamp, t != ts { flush() }
        timestamp = ts

        let type = p[offset] & 0x1f
        switch type {
        case 1...23:
            nals.append(Array(p[offset..<end]))
        case 24: // STAP-A
            var i = offset + 1
            while i + 2 <= end {
                let size = Int(p[i]) << 8 | Int(p[i + 1])
                i += 2
                guard size > 0, i + size <= end else { break }
                nals.append(Array(p[i..<i + size]))
                i += size
            }
        case 28: // FU-A
            guard end - offset > 2 else { return }
            let header = p[offset + 1]
            if header & 0x80 != 0 {
                fragment = [(p[offset] & 0xe0) | (header & 0x1f)]
            }
            guard fragment != nil else { return }
            fragment!.append(contentsOf: p[(offset + 2)..<end])
            if header & 0x40 != 0 {
                nals.append(fragment!)
                fragment = nil
            }
        default:
            break
        }
        if marker { flush() }
    }

    private func flush() {
        if !nals.isEmpty { onAccessUnit(nals) }
        nals.removeAll()
    }
}

// MARK: - Decoder

final class H264Decoder {
    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = true

    func setParameterSets(_ s: [UInt8], _ p: [UInt8]) {
        if s != sps || p != pps { sps = s; pps = p; reset() }
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        waitingForKeyframe = true
    }

    func decode(_ nals: [[UInt8]]) {
        var frame = [[UInt8]]()
        var keyframe = false
        for nal in nals where !nal.isEmpty {
            switch nal[0] & 0x1f {
            case 7: if nal != sps { sps = nal; reset() }
            case 8: if nal != pps { pps = nal; reset() }
            case 5: keyframe = true; frame.append(nal)
            case 1: frame.append(nal)
            default: break // SEI, AUD, etc.
            }
        }
        guard !frame.isEmpty, makeSessionIfNeeded(), let session, let format else { return }
        if waitingForKeyframe {
            guard keyframe else { return }
            waitingForKeyframe = false
        }

        var data = [UInt8]()
        data.reserveCapacity(frame.reduce(0) { $0 + $1.count + 4 })
        for nal in frame {
            let n = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: n) { data.append(contentsOf: $0) }
            data.append(contentsOf: nal)
        }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }) == noErr
        else { return }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return }

        let onFrame = self.onFrame
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { onFrame(image) }
        }
        if status == kVTInvalidSessionErr { reset() }
    }

    private func makeSessionIfNeeded() -> Bool {
        if session != nil { return true }
        guard let sps, let pps else { return false }
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else { return false }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                                           imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &s) == noErr, let s
        else { return false }
        format = fmt
        session = s
        waitingForKeyframe = true
        return true
    }

    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}

// MARK: - Stream controller

/// Runs the connection on a background thread and reconnects automatically.
final class CameraStream {
    enum Status { case connecting, live, failed(String) }

    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    var onStatus: (Status) -> Void = { _ in }

    private final class Run {
        private let lock = NSLock()
        private var _cancelled = false
        var socket: TCPSocket?
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() {
            lock.lock(); _cancelled = true; let s = socket; lock.unlock()
            s?.interrupt()
        }
        func attach(_ s: TCPSocket?) { lock.lock(); socket = s; lock.unlock() }
    }

    private var current: Run?

    func start(host: String, port: Int, path: String, username: String, password: String) {
        stop()
        let run = Run()
        current = run
        let url = "rtsp://\(host):\(port)/\(path)"
        let thread = Thread { [weak self] in
            while !run.cancelled {
                self?.report(.connecting, run)
                do {
                    let socket = try TCPSocket(host: host, port: port, timeout: 8)
                    run.attach(socket)
                    defer { run.attach(nil); socket.close() }
                    if run.cancelled { break }

                    let decoder = H264Decoder()
                    var live = false
                    decoder.onFrame = { [weak self] image in
                        DispatchQueue.main.async {
                            guard let self, self.current === run else { return }
                            if !live { live = true; self.onStatus(.live) }
                            self.onFrame(image)
                        }
                    }
                    let depacketizer = H264Depacketizer()
                    depacketizer.onAccessUnit = { decoder.decode($0) }
                    let client = RTSPClient(socket: socket, url: url, username: username, password: password)
                    try client.play(sprops: { if let p = $0 { decoder.setParameterSets(p.0, p.1) } },
                                    isCancelled: { run.cancelled },
                                    packet: depacketizer.handle)
                } catch {
                    if run.cancelled { break }
                    self?.report(.failed(error.localizedDescription), run)
                }
                for _ in 0..<30 where !run.cancelled { Thread.sleep(forTimeInterval: 0.1) }
            }
        }
        thread.name = "RTSP"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        current?.cancel()
        current = nil
    }

    private func report(_ status: Status, _ run: Run) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.current === run else { return }
            self.onStatus(status)
        }
    }
}
