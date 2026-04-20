import Darwin
import Foundation

final class IcmpPinger: @unchecked Sendable {
    private var sockfd: Int32 = -1
    private var dst = sockaddr_in()
    private let ident: UInt16
    private var seq: UInt16 = 0
    private let timeoutMs: UInt32

    init?(host: String, timeoutMs: UInt32 = 1000) {
        self.ident = UInt16(truncatingIfNeeded: getpid())
        self.timeoutMs = timeoutMs > 0 ? timeoutMs : 1000

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM

        var res: UnsafeMutablePointer<addrinfo>?
        let rc = host.withCString { cHost in
            getaddrinfo(cHost, nil, &hints, &res)
        }
        guard rc == 0, let ai = res else { return nil }
        defer { freeaddrinfo(ai) }

        var fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if fd < 0 { fd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP) }
        guard fd >= 0 else { return nil }

        guard let aiAddr = ai.pointee.ai_addr else {
            close(fd)
            return nil
        }
        aiAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
            dst = sinPtr.pointee
        }
        dst.sin_port = 0
        sockfd = fd
    }

    deinit {
        if sockfd >= 0 { close(sockfd) }
    }

    /// Sends one ICMP echo and waits for a matching reply. Blocking.
    /// Must not be invoked concurrently against the same instance.
    func ping() -> Double? {
        seq &+= 1
        let mySeq = seq

        var pkt = [UInt8](repeating: 0, count: 8)
        pkt[0] = 8
        pkt[4] = UInt8(ident >> 8)
        pkt[5] = UInt8(ident & 0xff)
        pkt[6] = UInt8(mySeq >> 8)
        pkt[7] = UInt8(mySeq & 0xff)
        let ck = Self.checksum(pkt)
        pkt[2] = UInt8(ck & 0xff)
        pkt[3] = UInt8(ck >> 8)

        let t0 = nowUs()

        let sent: Int = pkt.withUnsafeBufferPointer { buf in
            withUnsafePointer(to: &dst) { dstPtr in
                dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Int(sendto(sockfd, buf.baseAddress, buf.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size)))
                }
            }
        }
        guard sent >= 0 else { return nil }

        let timeoutUs = UInt64(timeoutMs) * 1000
        var recvBuf = [UInt8](repeating: 0, count: 2048)

        while true {
            let elapsed = nowUs() - t0
            if elapsed >= timeoutUs { return nil }
            let remainingMs = Int32((timeoutUs - elapsed + 999) / 1000)

            var pfd = pollfd()
            pfd.fd = sockfd
            pfd.events = Int16(POLLIN)
            let r = poll(&pfd, 1, remainingMs)
            if r < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if r == 0 { return nil }

            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n: Int = recvBuf.withUnsafeMutableBufferPointer { rbuf in
                withUnsafeMutablePointer(to: &from) { fromPtr in
                    fromPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Int(recvfrom(sockfd, rbuf.baseAddress, rbuf.count, 0, sa, &fromLen))
                    }
                }
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }

            var off = 0
            if n > 0 && (recvBuf[0] >> 4) == 4 {
                off = Int(recvBuf[0] & 0x0f) * 4
            }
            if n < off + 8 { continue }

            let type = recvBuf[off]
            let replySeq = (UInt16(recvBuf[off + 6]) << 8) | UInt16(recvBuf[off + 7])
            if type != 0 { continue }
            if replySeq != mySeq { continue }

            return Double(nowUs() - t0) / 1000.0
        }
    }

    private static func checksum(_ b: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < b.count {
            sum &+= UInt32(b[i]) | (UInt32(b[i + 1]) << 8)
            i += 2
        }
        if i < b.count { sum &+= UInt32(b[i]) }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }
}

private func nowUs() -> UInt64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return UInt64(tv.tv_sec) * 1_000_000 + UInt64(tv.tv_usec)
}
