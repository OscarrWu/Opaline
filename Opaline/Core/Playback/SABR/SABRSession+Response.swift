import Foundation

/// `MEDIA_HEADER` — what the following `MEDIA` parts belong to.
private struct MediaHeader {
    let itag: Int
    let startRange: Int64
    let sequence: Int
    let isInit: Bool
    let bufferedMs: Int

    /// Fields 1/3/6/8/9/15 of the message; 15 is a `TimeRange` whose own fields
    /// are start, duration and timescale.
    init?(_ payload: Data) {
        let fields = Protobuf.parse(payload)
        guard let itag = fields.number(3) else {
            return nil
        }
        self.itag = itag
        startRange = Int64(fields.number(6) ?? 0)
        sequence = fields.number(9) ?? 0
        isInit = (fields.number(8) ?? 0) != 0
        guard let range = fields.data(15) else {
            bufferedMs = 0
            return
        }
        let time = Protobuf.parse(range)
        let scale = time.number(3) ?? 1_000
        let start = time.number(1) ?? 0
        let duration = time.number(2) ?? 0
        bufferedMs = scale > 0 ? (start + duration) * 1_000 / scale : 0
    }
}

extension SABRSession {
    /// Folds one response into the session: media into the buffer, policy into
    /// the state carried by the next request.
    func consume(_ response: HTTPResponse) -> Result<Void, Error> {
        guard response.status == 200 else {
            return .failure(SABRError.server("HTTP \(response.status)"))
        }
        let reader = UMPReader()
        reader.append(response.data)
        var headers: [Int: MediaHeader] = [:]
        var sawMedia = false

        let parts = reader.readParts()
        for part in parts {
            if let failure = failure(in: part) {
                return .failure(failure)
            }
            sawMedia = apply(part, headers: &headers) || sawMedia
        }
        sawMediaInLastResponse = sawMedia
        if sawMedia {
            jumpPending = false
        }
        AppLog.hls("sabr resp parts=\(parts.map(\.type)) sawMedia=\(sawMedia)")
        if !sawMedia {
            return handleMediaLessResponse(parts: parts)
        }
        return .success(())
    }

    /// Applies one part; returns whether it carried media.
    private func apply(_ part: UMPPart, headers: inout [Int: MediaHeader]) -> Bool {
        switch UMPPartType(rawValue: part.type) {
        case .mediaHeader:
            // Field 1 is the header id the MEDIA parts refer back to.
            let id = Protobuf.parse(part.payload).number(1) ?? 0
            headers[id] = MediaHeader(part.payload)
        case .media:
            // Init segments do not count: at the end of a stream the server
            // keeps answering with those alone, and treating them as media
            // meant the session never noticed it had finished and asked again
            // forever.
            return store(media: part.payload, headers: headers)
        case .nextRequestPolicy:
            if let cookie = Protobuf.parse(part.payload).data(7) {
                setPlaybackCookie(cookie)
                AppLog.hls("sabr cookie: \(cookie.count)B")
            }
        case .streamProtectionStatus:
            // 1 = OK, 2 = attestation pending, 3 = attestation required. The
            // only direct answer to "does this session need a PO token".
            let status = Protobuf.parse(part.payload).number(1) ?? 0
            AppLog.hls("sabr stream protection status: \(status)")
        default:
            break
        }
        return false
    }

    /// The two parts that mean the session cannot continue as it stands.
    private func failure(in part: UMPPart) -> Error? {
        switch UMPPartType(rawValue: part.type) {
        case .sabrError:
            let fields = Protobuf.parse(part.payload)
            let text = String(data: part.payload.prefix(80), encoding: .isoLatin1) ?? ""
            AppLog.hls("sabr error: fields=\(fields.keys.sorted()) raw=\(text.debugDescription)")
            return SABRError.server("server rejected the request")
        case .reloadPlayerResponse:
            // The server demands a fresh player for this session (part 46).
            // Rebuild at the session's current playhead.
            AppLog.hls("sabr reload: player response expired, rebuilding at \(lastServedMs)ms")
            requestReload(at: lastServedMs)
            return SABRError.server("player response expired")
        default:
            return nil
        }
    }

    /// A response without media: a pending jump means the seek failed and the
    /// session must be rebuilt; otherwise the server declined the session.
    private func handleMediaLessResponse(parts: [UMPPart]) -> Result<Void, Error> {
        if jumpPending {
            AppLog.hls("sabr jump: no media, rebuilding at \(lastServedMs)ms")
            requestReload(at: lastServedMs)
            return .failure(SABRError.server("sabr seek needs reload"))
        }
        AppLog.hls("sabr declined, parts: \(parts.map(\.type))")
        markEnded()
        return .success(())
    }

    /// Asks the delivery to rebuild the session at `timeMs`. Fired once per
    /// session; afterwards the session marks itself ended so stray reads from
    /// the old item fail fast instead of firing competing requests.
    private func requestReload(at timeMs: Int) {
        guard !reloadRequested else {
            return
        }
        reloadRequested = true
        markEnded()
        let handler = onReloadRequested
        DispatchQueue.main.async {
            handler?(timeMs)
        }
    }

    /// A `MEDIA` payload leads with the varint header id its bytes belong to.
    private func store(media payload: Data, headers: [Int: MediaHeader]) -> Bool {
        guard let (id, offset) = Protobuf.readVarint(payload, 0),
              let header = headers[Int(id)] else {
            return false
        }
        let start = payload.startIndex + offset
        guard start < payload.endIndex else {
            return false
        }
        let data = payload[start..<payload.endIndex]
        let isMedia = !header.isInit
        // Media arrives in several parts per segment; each continues where the
        // previous one stopped, so position by what is already buffered.
        let written = bufferedLength(itag: header.itag, from: header.startRange)
        logMedia(header, written: written, bytes: data.count)
        store(SABRSegment(
            itag: header.itag,
            start: header.startRange + written,
            data: data,
            isInit: header.isInit
        ))
        if isMedia {
            advance(
                itag: header.itag,
                sequence: header.sequence,
                bufferedMs: header.bufferedMs
            )
        }
        return isMedia
    }

    /// Diagnostics for the seek investigation: what the server sent for one
    /// media part and where it landed in the buffer.
    private func logMedia(_ header: MediaHeader, written: Int64, bytes: Int) {
        AppLog.hls(
            "media itag=\(header.itag) start=\(header.startRange) written=\(written)"
                + " seq=\(header.sequence) bufferedMs=\(header.bufferedMs)"
                + " init=\(header.isInit) bytes=\(bytes)"
        )
    }
}

enum SABRError: LocalizedError {
    case noInitSegment
    case stalled
    case server(String)

    var errorDescription: String? {
        switch self {
        case .noInitSegment:
            "SABR returned no init segment"
        case .stalled:
            "SABR stopped returning media"
        case .server(let detail):
            "SABR error: \(detail)"
        }
    }
}
