import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreGraphics
import AppKit

// MARK: - Configuration

let HTTP_PORT: UInt16 = 8080
let TARGET_FPS = 30
let BITRATE = 15_000_000  // 15 Mbps — good quality, Tailscale handles it fine
let KEYFRAME_INTERVAL = 60 // keyframe every 2 seconds at 30fps

// MARK: - Global State

var connectedClients: [WebSocketClient] = []
let clientLock = NSLock()

// MARK: - Entry Point

print("""
╔══════════════════════════════════════╗
║       Mac Visibility Host            ║
║  Low-latency screen streaming        ║
╚══════════════════════════════════════╝
""")

// Request screen recording permission
print("[*] Requesting screen capture permission...")

// Get available displays
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first else {
    print("[!] No displays found")
    exit(1)
}

print("[*] Capturing display: \(display.width)x\(display.height)")

// Create encoder
let encoder = HardwareEncoder(width: display.width, height: display.height)

// Start HTTP/WebSocket server
let server = HTTPServer(port: HTTP_PORT)
Task { await server.start() }

// Configure capture
let config = SCStreamConfiguration()
config.width = display.width
config.height = display.height
config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(TARGET_FPS))
config.pixelFormat = kCVPixelFormatType_32BGRA
config.queueDepth = 3
config.showsCursor = true

let filter = SCContentFilter(display: display, excludingWindows: [])
let stream = SCStream(filter: filter, configuration: config, delegate: nil)

let handler = StreamHandler(encoder: encoder)
try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

try await stream.startCapture()

// Get Tailscale IP if available
let tailscaleIP = getTailscaleIP()
print("[*] Server running on port \(HTTP_PORT)")
print("[*] Open in browser: http://localhost:\(HTTP_PORT)")
if let ip = tailscaleIP {
    print("[*] Tailscale URL: http://\(ip):\(HTTP_PORT)")
}
print("[*] Streaming at \(TARGET_FPS)fps, \(BITRATE/1_000_000)Mbps H.264")
print("[*] Waiting for connections...")

// Keep running
RunLoop.main.run()

// MARK: - Tailscale IP Detection

func getTailscaleIP() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ifconfig")
    process.arguments = ["utun"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // Find 100.x.x.x addresses (Tailscale CGNAT range)
    let lines = output.components(separatedBy: "\n")
    for line in lines {
        if line.contains("inet 100.") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            if let idx = parts.firstIndex(of: "inet"), idx + 1 < parts.count {
                return parts[idx + 1]
            }
        }
    }
    return nil
}

// MARK: - Stream Handler

class StreamHandler: NSObject, SCStreamOutput {
    let encoder: HardwareEncoder
    var frameCount = 0

    init(encoder: HardwareEncoder) {
        self.encoder = encoder
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameCount += 1
        let forceKeyframe = frameCount % KEYFRAME_INTERVAL == 0

        encoder.encode(pixelBuffer: pixelBuffer, forceKeyframe: forceKeyframe) { nalUnits in
            self.broadcastToClients(nalUnits)
        }
    }

    func broadcastToClients(_ data: Data) {
        clientLock.lock()
        let clients = connectedClients
        clientLock.unlock()

        for client in clients {
            client.send(data)
        }
    }
}

// MARK: - Hardware Encoder (VideoToolbox H.264)

class HardwareEncoder {
    private var session: VTCompressionSession?
    private var callback: ((Data) -> Void)?
    private let width: Int
    private let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        setupSession()
    }

    private func setupSession() {
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            print("[!] Failed to create compression session: \(status)")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: BITRATE as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: KEYFRAME_INTERVAL as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        // Low latency tuning
        if #available(macOS 13.0, *) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: 36 as CFNumber)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[*] H.264 hardware encoder ready (\(width)x\(height))")
    }

    func encode(pixelBuffer: CVPixelBuffer, forceKeyframe: Bool, completion: @escaping (Data) -> Void) {
        guard let session else { return }
        self.callback = completion

        var properties: [String: Any] = [:]
        if forceKeyframe {
            properties[kVTEncodeFrameOptionKey_ForceKeyFrame as String] = true
        }

        let timestamp = CMTime(value: Int64(CACurrentMediaTime() * 1000), timescale: 1000)

        let refcon = Unmanaged.passRetained(self).toOpaque()

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: properties.isEmpty ? nil : properties as CFDictionary,
            infoFlagsOut: nil
        ) { status, flags, sampleBuffer in
            defer { Unmanaged<HardwareEncoder>.fromOpaque(refcon).release() }
            guard status == noErr, let sampleBuffer else { return }

            // Extract H.264 NAL units
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

            guard let dataPointer, totalLength > 0 else { return }

            var result = Data()

            // Check if this is a keyframe — if so, prepend SPS/PPS
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            var isKeyframe = false
            if let attachments, CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
                let notSync = CFDictionaryContainsKey(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
                isKeyframe = !notSync
            }

            if isKeyframe {
                // Get SPS and PPS from format description
                if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                    var spsPtr: UnsafePointer<UInt8>?
                    var spsSize = 0
                    var ppsPtr: UnsafePointer<UInt8>?
                    var ppsSize = 0

                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)

                    let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
                    if let spsPtr {
                        result.append(contentsOf: startCode)
                        result.append(UnsafeBufferPointer(start: spsPtr, count: spsSize))
                    }
                    if let ppsPtr {
                        result.append(contentsOf: startCode)
                        result.append(UnsafeBufferPointer(start: ppsPtr, count: ppsSize))
                    }
                }
            }

            // Convert AVCC length-prefixed NALUs to Annex B (start codes)
            var offset = 0
            let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
            while offset < totalLength {
                var naluLength: UInt32 = 0
                memcpy(&naluLength, dataPointer + offset, 4)
                naluLength = naluLength.bigEndian
                offset += 4

                result.append(contentsOf: startCode)
                result.append(Data(bytes: dataPointer + offset, count: Int(naluLength)))
                offset += Int(naluLength)
            }

            completion(result)
        }
    }
}

// MARK: - Simple HTTP + WebSocket Server

class HTTPServer {
    let port: UInt16
    private var listener: Task<Void, Never>?

    init(port: UInt16) {
        self.port = port
    }

    func start() async {
        let socket = socket(AF_INET6, SOCK_STREAM, 0)
        guard socket >= 0 else {
            print("[!] Failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            print("[!] Failed to bind to port \(port): \(String(cString: strerror(errno)))")
            return
        }

        Darwin.listen(socket, 10)

        while true {
            var clientAddr = sockaddr_in6()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(socket, sockPtr, &addrLen)
                }
            }

            guard clientSocket >= 0 else { continue }

            Task.detached {
                await self.handleConnection(clientSocket)
            }
        }
    }

    private func handleConnection(_ socket: Int32) async {
        // Read HTTP request
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { close(socket); return }

        let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

        if request.contains("Upgrade: websocket") {
            // WebSocket upgrade
            handleWebSocketUpgrade(socket: socket, request: request)
        } else if request.hasPrefix("GET / ") || request.hasPrefix("GET /index.html") {
            // Serve the web client
            let html = WebClientHTML.html
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            _ = response.withCString { send(socket, $0, strlen($0), 0) }
            close(socket)
        } else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = response.withCString { send(socket, $0, strlen($0), 0) }
            close(socket)
        }
    }

    private func handleWebSocketUpgrade(socket: Int32, request: String) {
        // Extract Sec-WebSocket-Key
        guard let keyLine = request.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key:") }),
              let key = keyLine.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) else {
            close(socket)
            return
        }

        // Generate accept key
        let magic = "258EAFA5-E914-47DA-95CA-5AB5C0AB43DC"
        let combined = key + magic
        let sha1 = sha1Hash(combined)
        let acceptKey = Data(sha1).base64EncodedString()

        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        _ = response.withCString { send(socket, $0, strlen($0), 0) }

        let client = WebSocketClient(socket: socket)
        clientLock.lock()
        connectedClients.append(client)
        let count = connectedClients.count
        clientLock.unlock()

        print("[+] Client connected (\(count) total)")

        // Keep connection alive — read pings/close frames
        client.readLoop {
            clientLock.lock()
            connectedClients.removeAll { $0 === client }
            let remaining = connectedClients.count
            clientLock.unlock()
            print("[-] Client disconnected (\(remaining) remaining)")
            close(socket)
        }
    }
}

// MARK: - WebSocket Client

class WebSocketClient {
    let socket: Int32
    private let writeLock = NSLock()

    init(socket: Int32) {
        self.socket = socket
    }

    func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }

        // WebSocket binary frame
        var frame = Data()
        frame.append(0x82) // FIN + binary opcode

        let length = data.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        frame.append(data)

        frame.withUnsafeBytes { ptr in
            _ = Darwin.send(socket, ptr.baseAddress!, frame.count, MSG_NOSIGNAL)
        }
    }

    func readLoop(onDisconnect: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = recv(self.socket, &buffer, buffer.count, 0)
                if n <= 0 {
                    onDisconnect()
                    return
                }
                // We don't need to process incoming frames for now
                // (input control would go here later)
            }
        }
    }
}

// MARK: - SHA-1 (for WebSocket handshake)

func sha1Hash(_ string: String) -> [UInt8] {
    let data = Array(string.utf8)
    var hash = [UInt8](repeating: 0, count: 20)

    var h0: UInt32 = 0x67452301
    var h1: UInt32 = 0xEFCDAB89
    var h2: UInt32 = 0x98BADCFE
    var h3: UInt32 = 0x10325476
    var h4: UInt32 = 0xC3D2E1F0

    var message = data
    let originalLength = message.count
    message.append(0x80)
    while message.count % 64 != 56 {
        message.append(0x00)
    }
    let bitLength = UInt64(originalLength * 8)
    for i in (0..<8).reversed() {
        message.append(UInt8((bitLength >> (i * 8)) & 0xFF))
    }

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let offset = chunkStart + i * 4
            w[i] = UInt32(message[offset]) << 24 | UInt32(message[offset+1]) << 16 |
                   UInt32(message[offset+2]) << 8 | UInt32(message[offset+3])
        }
        for i in 16..<80 {
            w[i] = (w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16])
            w[i] = (w[i] << 1) | (w[i] >> 31)
        }

        var a = h0, b = h1, c = h2, d = h3, e = h4

        for i in 0..<80 {
            var f: UInt32, k: UInt32
            if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999 }
            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1 }
            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC }
            else { f = b ^ c ^ d; k = 0xCA62C1D6 }

            let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
        }

        h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
    }

    for (i, h) in [h0, h1, h2, h3, h4].enumerated() {
        hash[i*4] = UInt8((h >> 24) & 0xFF)
        hash[i*4+1] = UInt8((h >> 16) & 0xFF)
        hash[i*4+2] = UInt8((h >> 8) & 0xFF)
        hash[i*4+3] = UInt8(h & 0xFF)
    }

    return hash
}

// MARK: - MSG_NOSIGNAL compatibility
#if !canImport(Glibc)
let MSG_NOSIGNAL: Int32 = 0 // macOS doesn't have MSG_NOSIGNAL, use SO_NOSIGPIPE instead
#endif
