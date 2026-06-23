import Foundation
import CoreVideo
import CoreMedia
import LiveKitWebRTC

struct WebRTCIceServerPayload: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct WebRTCOfferPayload: Codable {
    let type: String
    let sdp: String
    let codec: String?
    let iceServers: [WebRTCIceServerPayload]?
}

struct WebRTCAnswerPayload: Codable {
    let type: String
    let sdp: String
}

final class WebRTCPublisher {
    var onInput: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "webrtc-publisher")
    private let factory = LKRTCPeerConnectionFactory()
    private let videoSource: LKRTCVideoSource
    private let videoTrack: LKRTCVideoTrack
    private let capturer: LKRTCVideoCapturer
    private var session: WebRTCSession?
    private var lastOutputWidth = 0
    private var lastOutputHeight = 0
    private var sentFrameCount: Int64 = 0
    private var lastFrameTimestampNs: Int64 = 0
    var isActive: Bool {
        queue.sync { session != nil }
    }

    init() {
        videoSource = factory.videoSource(forScreenCast: true)
        videoTrack = factory.videoTrack(with: videoSource, trackId: "simulator-video")
        videoTrack.isEnabled = true
        capturer = LKRTCVideoCapturer(delegate: videoSource)
        print("[webrtc] Publisher ready (factory + screen-cast video source)")
    }

    func handleOffer(_ request: WebRTCOfferPayload) throws -> WebRTCAnswerPayload {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<WebRTCAnswerPayload, Error>?
        queue.async {
            self.createAnswer(request) { answerResult in
                result = answerResult
                semaphore.signal()
            }
        }
        semaphore.wait()
        return try result!.get()
    }

    func sendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        queue.async {
            guard self.session != nil else { return }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if width != self.lastOutputWidth || height != self.lastOutputHeight {
                self.lastOutputWidth = width
                self.lastOutputHeight = height
                self.videoSource.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 30)
                print("[webrtc] Video source output format: \(width)x\(height) @ 30fps")
            }
            let timeNs = self.nextFrameTimestampNs(timestamp)
            let frame = LKRTCVideoFrame(
                buffer: LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer),
                rotation: ._0,
                timeStampNs: timeNs
            )
            self.videoSource.capturer(self.capturer, didCapture: frame)
            self.sentFrameCount += 1
            if self.shouldLogFrame(self.sentFrameCount) {
                print("[webrtc] Sent video frame #\(self.sentFrameCount) size=\(width)x\(height) timestampNs=\(timeNs)")
            }
        }
    }

    private func nextFrameTimestampNs(_ timestamp: CMTime) -> Int64 {
        let captureTime = CMTimeGetSeconds(timestamp) * 1_000_000_000
        let proposedTimestamp = captureTime.isFinite && captureTime > 0
            ? Int64(captureTime)
            : Int64(DispatchTime.now().uptimeNanoseconds)
        let timestampNs = max(proposedTimestamp, lastFrameTimestampNs + 1)
        lastFrameTimestampNs = timestampNs
        return timestampNs
    }

    func stop() {
        queue.sync {
            session?.close()
            session = nil
        }
    }

    private func createAnswer(
        _ request: WebRTCOfferPayload,
        completion: @escaping (Result<WebRTCAnswerPayload, Error>) -> Void
    ) {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.candidateNetworkPolicy = .all
        config.continualGatheringPolicy = .gatherOnce
        config.iceServers = iceServers(from: request.iceServers)
        if hasCredentialedTurnServer(request.iceServers) {
            config.iceTransportPolicy = .relay
            print("[webrtc] ICE transport policy: relay")
        } else {
            config.iceTransportPolicy = .all
            print("[webrtc] ICE transport policy: all")
        }
        print("[webrtc] ICE servers: \(iceServerSummary(request.iceServers))")

        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        let delegate = WebRTCSessionDelegate(onInput: { [weak self] data in
            self?.onInput?(data)
        })
        guard let peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            completion(.failure(makeError("Failed to create peer connection")))
            return
        }

        let session = WebRTCSession(peerConnection: peerConnection, delegate: delegate)
        self.session?.close()
        self.session = session

        let remoteDescription = LKRTCSessionDescription(type: .offer, sdp: request.sdp)
        peerConnection.setRemoteDescription(remoteDescription) { error in
            if let error {
                completion(.failure(error))
                return
            }
            self.attachVideoTrack(to: peerConnection, codec: request.codec)
            peerConnection.answer(for: constraints) { answer, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let answer else {
                    completion(.failure(self.makeError("answer creation returned nil")))
                    return
                }
                peerConnection.setLocalDescription(answer) { error in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    session.waitForIceGathering { completed in
                        let local = peerConnection.localDescription ?? answer
                        let gatheredCandidates = delegate.generatedCandidatesSnapshot()
                        let finalSdp = self.sdpWithGatheredCandidates(
                            local.sdp,
                            candidates: gatheredCandidates
                        )
                        var candidateCounts = self.iceCandidateCounts(in: finalSdp)
                        if candidateCounts.isEmpty {
                            candidateCounts = self.iceCandidateCounts(in: gatheredCandidates)
                        }
                        if !completed {
                            print("[webrtc] ICE gathering timed out; proceeding with candidates gathered so far: \(candidateCounts)")
                        } else if self.hasCredentialedTurnServer(request.iceServers), candidateCounts["relay", default: 0] == 0 {
                            print("[webrtc] WARNING: no relay ICE candidates gathered for credentialed TURN offer; counts=\(candidateCounts)")
                        } else {
                            print("[webrtc] ICE candidates gathered: \(candidateCounts)")
                        }
                        completion(.success(WebRTCAnswerPayload(
                            type: LKRTCSessionDescription.string(for: local.type),
                            sdp: finalSdp
                        )))
                    }
                }
            }
        }
    }

    private func attachVideoTrack(to peerConnection: LKRTCPeerConnection, codec: String?) {
        let transceiver = peerConnection.transceivers.first { $0.mediaType == .video }
            ?? createFallbackVideoTransceiver(on: peerConnection)
        guard let transceiver else {
            _ = peerConnection.add(videoTrack, streamIds: ["stream0"])
            print("[webrtc] Could not find or create video transceiver; fell back to addTrack")
            return
        }

        transceiver.sender.track = videoTrack
        transceiver.sender.streamIds = ["stream0"]
        var directionError: NSError?
        transceiver.setDirection(.sendOnly, error: &directionError)
        if let directionError {
            print("[webrtc] Failed to set video transceiver direction: \(directionError.localizedDescription)")
        }
        applyVideoCodecPreference(codec, to: transceiver)
    }

    private func createFallbackVideoTransceiver(on peerConnection: LKRTCPeerConnection) -> LKRTCRtpTransceiver? {
        let initOptions = LKRTCRtpTransceiverInit()
        initOptions.direction = .sendOnly
        initOptions.streamIds = ["stream0"]
        return peerConnection.addTransceiver(with: videoTrack, init: initOptions)
    }

    private func iceServers(from payload: [WebRTCIceServerPayload]?) -> [LKRTCIceServer] {
        let servers = payload ?? [
            WebRTCIceServerPayload(urls: ["stun:stun.l.google.com:19302"], username: nil, credential: nil),
            WebRTCIceServerPayload(urls: ["stun:stun1.l.google.com:19302"], username: nil, credential: nil),
        ]
        return servers.flatMap { server in
            server.urls.map { url in
                LKRTCIceServer(
                    urlStrings: [url],
                    username: server.username,
                    credential: server.credential
                )
            }
        }
    }

    private func hasCredentialedTurnServer(_ payload: [WebRTCIceServerPayload]?) -> Bool {
        (payload ?? []).contains { server in
            guard
                let username = server.username, !username.isEmpty,
                let credential = server.credential, !credential.isEmpty
            else {
                return false
            }
            return server.urls.contains { $0.lowercased().hasPrefix("turn:") || $0.lowercased().hasPrefix("turns:") }
        }
    }

    private func iceServerSummary(_ payload: [WebRTCIceServerPayload]?) -> String {
        let servers = payload ?? []
        let stunUrls = servers.flatMap { server in
            server.urls.filter { $0.lowercased().hasPrefix("stun:") }
        }.count
        let turnUrls = servers.flatMap { server in
            server.urls.filter { $0.lowercased().hasPrefix("turn:") || $0.lowercased().hasPrefix("turns:") }
        }.count
        let credentialedTurnServers = servers.filter { server in
            let hasCredentials = !(server.username ?? "").isEmpty && !(server.credential ?? "").isEmpty
            return hasCredentials && server.urls.contains {
                $0.lowercased().hasPrefix("turn:") || $0.lowercased().hasPrefix("turns:")
            }
        }.count
        return "servers=\(servers.count) stunUrls=\(stunUrls) turnUrls=\(turnUrls) credentialedTurnServers=\(credentialedTurnServers)"
    }

    private func iceCandidateCounts(in sdp: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in sdp.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.hasPrefix("a=candidate:") else { continue }
            let parts = trimmedLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let typeIndex = parts.firstIndex(of: "typ"), parts.indices.contains(parts.index(after: typeIndex)) {
                counts[String(parts[parts.index(after: typeIndex)]), default: 0] += 1
            } else {
                counts["unknown", default: 0] += 1
            }
        }
        return counts
    }

    private func iceCandidateCounts(in candidates: [LKRTCIceCandidate]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for candidate in candidates {
            let candidateLine = candidate.sdp.hasPrefix("a=")
                ? candidate.sdp
                : "a=\(candidate.sdp)"
            let parts = candidateLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let typeIndex = parts.firstIndex(of: "typ"), parts.indices.contains(parts.index(after: typeIndex)) {
                counts[String(parts[parts.index(after: typeIndex)]), default: 0] += 1
            } else {
                counts["unknown", default: 0] += 1
            }
        }
        return counts
    }

    private func sdpWithGatheredCandidates(_ sdp: String, candidates: [LKRTCIceCandidate]) -> String {
        let newline = sdp.contains("\r\n") ? "\r\n" : "\n"
        var lines = sdp.components(separatedBy: newline)
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline {
            lines.removeLast()
        }
        var existingCandidateLines = Set<String>()
        var sectionsNeedingEndMarker = Set<Int>()
        var currentSection = -1
        for line in lines {
            if line.hasPrefix("m=") {
                currentSection += 1
            } else if line.hasPrefix("a=candidate:"), currentSection >= 0 {
                existingCandidateLines.insert(line)
                sectionsNeedingEndMarker.insert(currentSection)
            }
        }
        var sectionCandidates: [Int: [String]] = [:]

        for candidate in candidates {
            let candidateLine = candidate.sdp.hasPrefix("a=")
                ? candidate.sdp
                : "a=\(candidate.sdp)"
            let sectionIndex = mediaSectionIndex(
                in: lines,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )
            sectionsNeedingEndMarker.insert(sectionIndex)
            guard !existingCandidateLines.contains(candidateLine) else { continue }
            existingCandidateLines.insert(candidateLine)
            sectionCandidates[sectionIndex, default: []].append(candidateLine)
        }

        for sectionIndex in sectionsNeedingEndMarker.sorted(by: >) {
            let sectionRange = mediaSectionRange(in: lines, sectionIndex: sectionIndex)
            let insertIndex = endOfCandidatesIndex(in: lines, range: sectionRange) ?? sectionRange.upperBound
            var insertedLines = sectionCandidates[sectionIndex] ?? []
            if endOfCandidatesIndex(in: lines, range: sectionRange) == nil {
                insertedLines.append("a=end-of-candidates")
            }
            guard !insertedLines.isEmpty else { continue }
            lines.insert(contentsOf: insertedLines, at: insertIndex)
        }

        let body = lines.joined(separator: newline)
        return hadTrailingNewline ? "\(body)\(newline)" : body
    }

    private func mediaSectionIndex(
        in lines: [String],
        sdpMid: String?,
        sdpMLineIndex: Int32
    ) -> Int {
        if let sdpMid {
            var currentSection = -1
            for line in lines {
                if line.hasPrefix("m=") {
                    currentSection += 1
                } else if line == "a=mid:\(sdpMid)", currentSection >= 0 {
                    return currentSection
                }
            }
        }
        let candidateIndex = Int(sdpMLineIndex)
        return candidateIndex >= 0 ? candidateIndex : 0
    }

    private func mediaSectionRange(in lines: [String], sectionIndex: Int) -> Range<Int> {
        var currentSection = -1
        var start = lines.count
        for (index, line) in lines.enumerated() where line.hasPrefix("m=") {
            currentSection += 1
            if currentSection == sectionIndex {
                start = index
            } else if currentSection > sectionIndex, start < lines.count {
                return start..<index
            }
        }
        if start < lines.count {
            return start..<lines.count
        }
        return lines.count..<lines.count
    }

    private func endOfCandidatesIndex(in lines: [String], range: Range<Int>) -> Int? {
        for index in range {
            if lines[index] == "a=end-of-candidates" {
                return index
            }
        }
        return nil
    }

    private func applyVideoCodecPreference(_ codec: String?, to transceiver: LKRTCRtpTransceiver) {
        let preferredName: String
        switch codec?.lowercased() {
        case "vp8":
            preferredName = "VP8"
        case "vp9":
            preferredName = "VP9"
        default:
            preferredName = "H264"
        }
        let capabilities = factory.rtpSenderCapabilities(forKind: "video")
        let preferredCodecs = capabilities.codecs.filter {
            $0.name.caseInsensitiveCompare(preferredName) == .orderedSame ||
                $0.mimeType.caseInsensitiveCompare("video/\(preferredName)") == .orderedSame
        }
        guard !preferredCodecs.isEmpty else {
            print("[webrtc] No sender codec capability found for \(preferredName); using default order")
            return
        }
        let remainingCodecs = capabilities.codecs.filter { capability in
            !preferredCodecs.contains { $0 === capability }
        }
        let orderedCodecs = preferredCodecs + remainingCodecs
        transceiver.codecPreferences = orderedCodecs
        print("[webrtc] Preferred video codec: \(preferredName)")
    }

    private func makeError(_ message: String) -> Error {
        NSError(domain: "serve-sim.webrtc", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func shouldLogFrame(_ count: Int64) -> Bool {
        count <= 5 || count % 120 == 0
    }
}

private final class WebRTCSession {
    let peerConnection: LKRTCPeerConnection
    let delegate: WebRTCSessionDelegate
    private let iceGatheringTimeout: DispatchTimeInterval = .milliseconds(3_000)

    init(peerConnection: LKRTCPeerConnection, delegate: WebRTCSessionDelegate) {
        self.peerConnection = peerConnection
        self.delegate = delegate
    }

    func waitForIceGathering(_ completion: @escaping (Bool) -> Void) {
        let lock = NSLock()
        var finished = false
        let finish = { [weak delegate] (completed: Bool) in
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            delegate?.setIceGatheringCompleteHandler(nil)
            lock.unlock()
            completion(completed)
        }
        delegate.setIceGatheringCompleteHandler {
            finish(true)
        }
        if peerConnection.iceGatheringState == .complete {
            finish(true)
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + iceGatheringTimeout) {
            finish(false)
        }
    }

    func close() {
        peerConnection.close()
    }
}

private final class WebRTCSessionDelegate: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    private let onInput: (Data) -> Void
    private let iceGatheringCompleteHandlerLock = NSLock()
    private var iceGatheringCompleteHandler: (() -> Void)?
    private let candidatesLock = NSLock()
    private var generatedCandidates: [LKRTCIceCandidate] = []
    private var statsScheduled = false

    init(onInput: @escaping (Data) -> Void) {
        self.onInput = onInput
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        print("[webrtc] ICE connection state: \(newState.rawValue)")
        if newState == .connected || newState == .completed {
            scheduleOutboundStats(peerConnection)
        }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        print("[webrtc] ICE gathering state: \(newState.rawValue)")
        if newState == .complete {
            let completion = consumeIceGatheringCompleteHandler()
            completion?()
        }
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        candidatesLock.lock()
        generatedCandidates.append(candidate)
        candidatesLock.unlock()
        print("[webrtc] ICE candidate gathered: \(candidateSummary(candidate))")
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didChangeLocalCandidate local: LKRTCIceCandidate,
        remoteCandidate remote: LKRTCIceCandidate,
        lastReceivedMs: Int32,
        changeReason: String
    ) {
        print("[webrtc] ICE selected pair: local=\(candidateSummary(local)) remote=\(candidateSummary(remote)) reason=\(changeReason) lastReceivedMs=\(lastReceivedMs)")
    }
    func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didFailToGatherIceCandidate event: LKRTCIceCandidateErrorEvent
    ) {
        print("[webrtc] ICE candidate error: url=\(event.url) code=\(event.errorCode) text=\(event.errorText)")
    }
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        print("[webrtc] viewer opened data channel: \(dataChannel.label)")
        dataChannel.delegate = self
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        onInput(buffer.data)
    }

    func generatedCandidatesSnapshot() -> [LKRTCIceCandidate] {
        candidatesLock.lock()
        let candidates = generatedCandidates
        candidatesLock.unlock()
        return candidates
    }

    func setIceGatheringCompleteHandler(_ handler: (() -> Void)?) {
        iceGatheringCompleteHandlerLock.lock()
        iceGatheringCompleteHandler = handler
        iceGatheringCompleteHandlerLock.unlock()
    }

    private func consumeIceGatheringCompleteHandler() -> (() -> Void)? {
        iceGatheringCompleteHandlerLock.lock()
        let handler = iceGatheringCompleteHandler
        iceGatheringCompleteHandler = nil
        iceGatheringCompleteHandlerLock.unlock()
        return handler
    }

    private func candidateSummary(_ candidate: LKRTCIceCandidate) -> String {
        let parts = candidate.sdp.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let protocolName = parts.indices.contains(2) ? String(parts[2]).lowercased() : "?"
        let address = parts.indices.contains(4) ? String(parts[4]) : "?"
        let port = parts.indices.contains(5) ? String(parts[5]) : "?"
        let type: String
        if let typeIndex = parts.firstIndex(of: "typ"), parts.indices.contains(parts.index(after: typeIndex)) {
            type = String(parts[parts.index(after: typeIndex)])
        } else {
            type = "unknown"
        }
        let server = candidate.serverUrl?.isEmpty == false ? " server=\(candidate.serverUrl!)" : ""
        return "type=\(type) protocol=\(protocolName) address=\(address) port=\(port)\(server)"
    }

    private func scheduleOutboundStats(_ peerConnection: LKRTCPeerConnection) {
        guard !statsScheduled else { return }
        statsScheduled = true
        logOutboundStats(peerConnection, label: "connected")
        for seconds in [2.0, 5.0, 10.0] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self, weak peerConnection] in
                guard let self, let peerConnection else { return }
                self.logOutboundStats(peerConnection, label: "+\(Int(seconds))s")
            }
        }
    }

    private func logOutboundStats(_ peerConnection: LKRTCPeerConnection, label: String) {
        peerConnection.statistics { report in
            let videoStats = report.statistics.values
                .filter { stat in
                    stat.type == "outbound-rtp" &&
                        ((stat.values["kind"] as? String) == "video" || (stat.values["mediaType"] as? String) == "video")
                }
                .map { stat in
                    self.statSummary(stat, keys: [
                        "bytesSent",
                        "packetsSent",
                        "framesEncoded",
                        "framesSent",
                        "keyFramesEncoded",
                        "hugeFramesSent",
                        "nackCount",
                        "firCount",
                        "pliCount",
                    ])
                }
            if videoStats.isEmpty {
                print("[webrtc] Outbound stats \(label): no video outbound-rtp stats")
            } else {
                print("[webrtc] Outbound stats \(label): \(videoStats.joined(separator: " | "))")
            }
        }
    }

    private func statSummary(_ stat: LKRTCStatistics, keys: [String]) -> String {
        let values = keys.compactMap { key -> String? in
            guard let value = stat.values[key] else { return nil }
            return "\(key)=\(value)"
        }
        return "\(stat.id){\(values.joined(separator: " "))}"
    }
}
