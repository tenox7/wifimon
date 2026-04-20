import Darwin
import Foundation

/// Reads the IPv4 default gateway from the kernel routing table via
/// sysctl(CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0). No privileges required.
func findDefaultGatewayIPv4() -> String? {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
    var len = 0
    let probe = mib.withUnsafeMutableBufferPointer { mp -> Int32 in
        sysctl(mp.baseAddress, UInt32(mp.count), nil, &len, nil, 0)
    }
    guard probe >= 0, len > 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: len)
    let fetch = mib.withUnsafeMutableBufferPointer { mp -> Int32 in
        buf.withUnsafeMutableBufferPointer { bp in
            sysctl(mp.baseAddress, UInt32(mp.count), bp.baseAddress, &len, nil, 0)
        }
    }
    guard fetch >= 0 else { return nil }

    let longSize = MemoryLayout<Int>.size
    var off = 0
    while off < len {
        guard len - off >= MemoryLayout<rt_msghdr>.size else { break }
        let rtm = buf.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self)
        }
        let msgLen = Int(rtm.rtm_msglen)
        if msgLen == 0 || msgLen > len - off { break }
        defer { off += msgLen }

        guard Int32(rtm.rtm_version) == RTM_VERSION else { continue }
        guard (rtm.rtm_flags & RTF_GATEWAY) != 0 else { continue }
        guard (rtm.rtm_addrs & RTA_DST) != 0 else { continue }
        guard (rtm.rtm_addrs & RTA_GATEWAY) != 0 else { continue }

        var addrOff = off + MemoryLayout<rt_msghdr>.size
        var isDefault = false
        var gateway: String?

        for i in 0..<Int(RTAX_MAX) {
            guard (rtm.rtm_addrs & (Int32(1) << i)) != 0 else { continue }
            guard addrOff + MemoryLayout<sockaddr>.size <= len else { break }
            let sa = buf.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: addrOff, as: sockaddr.self)
            }
            let saLen = Int(sa.sa_len)

            if Int32(i) == RTAX_DST, sa.sa_family == sa_family_t(AF_INET) {
                let sin = buf.withUnsafeBytes { raw in
                    raw.loadUnaligned(fromByteOffset: addrOff, as: sockaddr_in.self)
                }
                if sin.sin_addr.s_addr == 0 { isDefault = true }
            } else if Int32(i) == RTAX_GATEWAY, sa.sa_family == sa_family_t(AF_INET) {
                let sin = buf.withUnsafeBytes { raw in
                    raw.loadUnaligned(fromByteOffset: addrOff, as: sockaddr_in.self)
                }
                var addr = sin.sin_addr
                var s = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &s, socklen_t(INET_ADDRSTRLEN)) != nil {
                    gateway = String(cString: s)
                }
            }

            let step = saLen == 0 ? longSize : 1 + ((saLen - 1) | (longSize - 1))
            addrOff += step
        }

        if isDefault, let g = gateway {
            return g
        }
    }
    return nil
}
