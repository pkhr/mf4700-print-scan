// SPDX-License-Identifier: GPL-2.0-or-later
// Canon MF4780w Print & Scan: the printer's status over SNMP, from the app itself.
//
// One small UDP exchange per poll. Starting the encoder (`--find`) for it ran
// two /usr/bin/snmpget processes each time, about 130 ms of CPU per poll.

import Foundation

enum SNMP {
    static let descr = "1.3.6.1.2.1.1.1.0"              // sysDescr
    static let pages = "1.3.6.1.2.1.43.10.2.1.4.1.1"    // prtMarkerLifeCount
    static let state = "1.3.6.1.2.1.25.3.5.1.1.1"       // hrPrinterStatus: 3 idle, 4 printing, 5 warmup
    static let errors = "1.3.6.1.2.1.25.3.5.1.2.1"      // hrPrinterDetectedErrorState bits
    static let tonerMax = "1.3.6.1.2.1.43.11.1.1.8.1.1" // prtMarkerSuppliesMaxCapacity
    static let toner = "1.3.6.1.2.1.43.11.1.1.9.1.1"    // prtMarkerSuppliesLevel

    enum Value: Equatable {
        case int(Int)
        case bytes([UInt8])
        case none

        var int: Int? { if case .int(let v) = self { return v } else { return nil } }
        var bytes: [UInt8] { if case .bytes(let b) = self { return b } else { return [] } }
    }

    /// The printer's status as `rastertoufr2lt --find` prints it after the address
    /// ("idle 18034 0000 100": state, page counter, error bits, toner %), or nil
    /// when nothing answers there or it isn't a Canon.
    static func status(_ host: String) -> String? {
        guard let v = get(host, [descr, pages, state, errors, tonerMax, toner]),
              case .bytes(let d) = v[0], String(decoding: d, as: UTF8.self).contains("Canon") else { return nil }
        let names = [1: "other", 2: "unknown", 3: "idle", 4: "printing", 5: "warmup"]
        let bits = v[3].bytes + [0, 0]
        let max = v[4].int ?? 0, level = v[5].int ?? -1
        return String(format: "%@ %d %02x%02x %d", names[v[2].int ?? 0] ?? "unknown", v[1].int ?? 0,
                      bits[0], bits[1], max > 0 && level >= 0 ? level * 100 / max : -1)
    }

    /// SNMP v1 GET (community "public"), two tries of `timeout` seconds. The values
    /// come back in the order asked; nil without a valid answer.
    static func get(_ host: String, _ oids: [String], timeout: Double = 2) -> [Value]? {
        // the soak test's fake printer answers on an unprivileged port
        let port = UInt16(ProcessInfo.processInfo.environment["UFR2LT_SNMP_PORT"] ?? "") ?? 161
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1e6))
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        for _ in 0..<2 {
            let id = Int.random(in: 1..<0x7fff_ffff)
            let request = message(id: id, oids: oids)
            guard send(s, request, request.count, 0) == request.count else { return nil }
            var reply = [UInt8](repeating: 0, count: 1500)
            while true {                                 // skip stray answers to an earlier try
                let n = recv(s, &reply, reply.count, 0)
                if n <= 0 { break }
                if let values = parse(Array(reply[..<n]), id: id, count: oids.count) { return values }
            }
        }
        return nil
    }

    // MARK: BER

    private static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        let length: [UInt8] = n < 0x80 ? [UInt8(n)] : n < 0x100 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
        return [tag] + length + body
    }

    private static func integer(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = [], x = v
        repeat { bytes.insert(UInt8(x & 0xff), at: 0); x >>= 8 } while x > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    private static func oid(_ dotted: String) -> [UInt8] {
        let p = dotted.split(separator: ".").compactMap { UInt($0) }
        var body = [UInt8(p[0] * 40 + p[1])]
        for v in p.dropFirst(2) {
            var enc = [UInt8(v & 0x7f)], x = v >> 7
            while x > 0 { enc.insert(UInt8(0x80 | (x & 0x7f)), at: 0); x >>= 7 }
            body += enc
        }
        return tlv(0x06, body)
    }

    private static func message(id: Int, oids: [String]) -> [UInt8] {
        let varbinds = oids.flatMap { tlv(0x30, oid($0) + [0x05, 0x00]) }
        let pdu = tlv(0xa0, integer(id) + integer(0) + integer(0) + tlv(0x30, varbinds))
        return tlv(0x30, integer(0) + tlv(0x04, Array("public".utf8)) + pdu)
    }

    /// Reads one TLV at `i`; nil when it doesn't fit.
    private static func read(_ b: [UInt8], _ i: inout Int) -> (tag: UInt8, body: ArraySlice<UInt8>)? {
        guard i + 2 <= b.count else { return nil }
        let tag = b[i]
        var n = Int(b[i + 1]), at = i + 2
        if n & 0x80 != 0 {
            let k = n & 0x7f
            guard k > 0, k <= 2, at + k <= b.count else { return nil }
            n = b[at..<(at + k)].reduce(0) { $0 << 8 | Int($1) }
            at += k
        }
        guard at + n <= b.count else { return nil }
        i = at + n
        return (tag, b[at..<(at + n)])
    }

    private static func items(_ body: ArraySlice<UInt8>) -> [(tag: UInt8, body: ArraySlice<UInt8>)]? {
        let b = Array(body)
        var i = 0, out: [(tag: UInt8, body: ArraySlice<UInt8>)] = []
        while i < b.count {
            guard let item = read(b, &i) else { return nil }
            out.append(item)
        }
        return out
    }

    private static func number(_ body: ArraySlice<UInt8>, signed: Bool) -> Int {
        guard let first = body.first else { return 0 }
        var v = signed && first & 0x80 != 0 ? -1 : 0
        for byte in body.prefix(8) { v = v << 8 | Int(byte) }
        return v
    }

    private static func parse(_ reply: [UInt8], id: Int, count: Int) -> [Value]? {
        var i = 0
        guard let msg = read(reply, &i), msg.tag == 0x30, let parts = items(msg.body), parts.count == 3,
              parts[2].tag == 0xa2, let pdu = items(parts[2].body), pdu.count == 4,
              number(pdu[0].body, signed: true) == id, number(pdu[1].body, signed: true) == 0,
              let binds = items(pdu[3].body), binds.count == count else { return nil }
        return binds.map { bind in
            guard let pair = items(bind.body), pair.count == 2 else { return .none }
            switch pair[1].tag {
            case 0x02: return .int(number(pair[1].body, signed: true))
            case 0x41, 0x42, 0x43: return .int(number(pair[1].body, signed: false))   // Counter32, Gauge32, TimeTicks
            case 0x04: return .bytes(Array(pair[1].body))
            default: return .none
            }
        }
    }
}
