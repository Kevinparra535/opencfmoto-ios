// SPDX-License-Identifier: AGPL-3.0-or-later
// `linkrunner --selftest`: exercises PosixNetworkProvider against the ByteStream / StreamListener /
// NetworkProvider contract on kernel-chosen ports (never the PXC ports, so no lock is needed).

import Foundation
import OpenCfMotoCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum TransportSelfTest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ cond: Bool, _ what: String) throws {
        if !cond { throw Failure(description: what) }
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private static func openDescriptorCount() -> Int? {
        (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd"))?.count
    }

    /// Returns 0 when every check passed.
    static func run() async -> Int32 {
        let net = PosixNetworkProvider()
        var failures = 0
        func report(_ name: String, _ body: () async throws -> String) async {
            let t0 = now()
            do {
                let detail = try await body()
                print(String(format: "PASS %-44@ %6.3fs  %@", name as NSString, now() - t0, detail as NSString))
            } catch {
                failures += 1
                print(String(format: "FAIL %-44@ %6.3fs  %@", name as NSString, now() - t0, "\(error)" as NSString))
            }
        }
        let fdBefore = openDescriptorCount()

        await report("listen/connect/accept, localPort = listener") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { c.close(); s.close() }
            try check(s.localPort == l.port, "accepted localPort \(s.localPort) != listener \(l.port)")
            try check(s.remoteHost == "127.0.0.1", "remoteHost \(s.remoteHost ?? "nil")")
            try check(c.localPort != 0 && c.localPort != l.port, "outbound localPort \(c.localPort)")
            return "listener :\(l.port), accepted from \(s.remoteEndpoint)"
        }

        await report("read(exactly:) across many small writes") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { c.close(); s.close() }
            let writer = Task {
                for i in 0 ..< 100 {
                    try await c.write(Data([UInt8(i)]))
                    if i % 10 == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
                }
            }
            let got = try await s.read(exactly: 100)
            try await writer.value
            try check(got == Data((0 ..< 100).map { UInt8($0) }), "bytes differ")
            return "100 bytes in order"
        }

        await report("8 MiB write (partial writes / EAGAIN path)") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { c.close(); s.close() }
            var big = Data(count: 8 << 20)
            big.withUnsafeMutableBytes { p in for i in 0 ..< p.count { p[i] = UInt8(truncatingIfNeeded: i &* 31) } }
            let payload = big
            let writer = Task { try await c.write(payload) }
            // Read slowly at first so the sender's buffer fills up.
            try await Task.sleep(nanoseconds: 200_000_000)
            var received = Data()
            while received.count < payload.count {
                received.append(try await s.readSome(maxCount: 1 << 16))
            }
            try await writer.value
            try check(received == payload, "payload differs")
            return "\(payload.count) bytes intact"
        }

        await report("concurrent writers keep frames whole, FIFO") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { c.close(); s.close() }
            let frameSize = 200_000
            let tasks = (0 ..< 8).map { k in
                Task { try await c.write(Data(repeating: UInt8(k), count: frameSize)) }
            }
            var frames: [UInt8] = []
            for _ in 0 ..< 8 {
                let f = try await s.read(exactly: frameSize)
                try check(Set(f).count == 1, "torn frame")
                frames.append(f.first!)
            }
            for t in tasks { try await t.value }
            try check(Set(frames).count == 8, "frames \(frames)")
            return "8 × \(frameSize) B frames, no interleaving"
        }

        await report("close() unblocks a pending read promptly") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { c.close() }
            let reader = Task { () -> String in
                do {
                    _ = try await s.read(exactly: 1)
                    return "read returned data"
                } catch {
                    return "\(error)"
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let t0 = now()
            s.close()
            let result = await reader.value
            let dt = now() - t0
            try check(result == "\(TransportError.closed)", "reader got \(result)")
            try check(dt < 0.2, "took \(dt)s")
            return String(format: "threw .closed after %.1f ms", dt * 1000)
        }

        await report("peer close → read throws .closed (EOF)") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { s.close() }
            try await c.write(Data([1, 2, 3]))
            c.close()
            let first = try await s.read(exactly: 3)
            do {
                _ = try await s.read(exactly: 1)
                throw Failure(description: "read after EOF returned data")
            } catch let e as TransportError {
                try check(e == .closed, "got \(e)")
            }
            do {
                _ = try await s.read(exactly: 5) // EOF mid-read
                throw Failure(description: "short read returned data")
            } catch let e as TransportError {
                try check(e == .closed, "got \(e)")
            }
            return "buffered \(first.count) B delivered, then .closed"
        }

        await report("close() unblocks a pending accept") {
            let l = try await net.listen(port: 0)
            let acceptor = Task { () -> String in
                do {
                    _ = try await l.accept()
                    return "accepted?"
                } catch {
                    return "\(error)"
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let t0 = now()
            l.close()
            let r = await acceptor.value
            try check(r == "\(TransportError.closed)", "accept got \(r)")
            return String(format: "threw .closed after %.1f ms", (now() - t0) * 1000)
        }

        await report("cancelled read throws .cancelled, stream still usable") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            async let accepted = l.accept()
            let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
            let s = try await accepted
            defer { c.close(); s.close() }
            let reader = Task { () -> String in
                do {
                    _ = try await s.read(exactly: 1)
                    return "data"
                } catch {
                    return "\(error)"
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            reader.cancel()
            let r = await reader.value
            try check(r == "\(TransportError.cancelled)", "cancelled reader got \(r)")
            try await c.write(Data([42]))
            let after = try await s.read(exactly: 1)
            try check(after == Data([42]), "data after cancellation \(after)")
            return "then read the next byte normally"
        }

        await report("connect refused → .failed quickly") {
            let l = try await net.listen(port: 0)
            let port = l.port
            l.close()
            try await Task.sleep(nanoseconds: 50_000_000)
            let t0 = now()
            do {
                let s = try await net.connect(host: "127.0.0.1", port: port, timeout: 2)
                s.close()
                throw Failure(description: "connected to a closed port")
            } catch let e as TransportError {
                guard case let .failed(m) = e else { throw Failure(description: "got \(e)") }
                try check(now() - t0 < 0.5, "slow refusal")
                return m
            }
        }

        await report("connect timeout → .timeout on time") {
            // A listener that never accepts with a full accept queue: further SYNs are dropped.
            let fd = socket(AF_INET, Int32(SOCK_STREAM_VALUE), 0)
            defer { close(fd) }
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = posixIPv4Address(host: "127.0.0.1", port: 0)!
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            _ = listen(fd, 0)
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            let port = UInt16(bigEndian: bound.sin_port)
            var fillers: [any ByteStream] = []
            defer { fillers.forEach { $0.close() } }
            for _ in 0 ..< 8 {
                if let s = try? await net.connect(host: "127.0.0.1", port: port, timeout: 0.3) { fillers.append(s) } else { break }
            }
            let t0 = now()
            do {
                let s = try await net.connect(host: "127.0.0.1", port: port, timeout: 0.5)
                s.close()
                throw Failure(description: "connected despite a full backlog (\(fillers.count) fillers)")
            } catch let e as TransportError {
                let dt = now() - t0
                try check(e == .timeout, "got \(e)")
                try check(dt >= 0.45 && dt < 0.8, "timeout after \(dt)s")
                return String(format: "%d queued, timed out after %.3f s", fillers.count, dt)
            }
        }

        await report("cancelled connect throws .cancelled") {
            let fd = socket(AF_INET, Int32(SOCK_STREAM_VALUE), 0)
            defer { close(fd) }
            var addr = posixIPv4Address(host: "127.0.0.1", port: 0)!
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            _ = listen(fd, 0)
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            let port = UInt16(bigEndian: bound.sin_port)
            var fillers: [any ByteStream] = []
            defer { fillers.forEach { $0.close() } }
            for _ in 0 ..< 8 {
                if let s = try? await net.connect(host: "127.0.0.1", port: port, timeout: 0.3) { fillers.append(s) } else { break }
            }
            let task = Task { () -> String in
                do {
                    _ = try await net.connect(host: "127.0.0.1", port: port, timeout: 5)
                    return "connected"
                } catch {
                    return "\(error)"
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let t0 = now()
            task.cancel()
            let r = await task.value
            try check(r == "\(TransportError.cancelled)", "got \(r)")
            return String(format: "after %.1f ms", (now() - t0) * 1000)
        }

        await report("port in use → listen throws") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            do {
                let again = try await net.listen(port: l.port)
                again.close()
                throw Failure(description: "second listen on :\(l.port) succeeded")
            } catch let e as TransportError {
                return "\(e)"
            }
        }

        await report("500 connect/accept/close cycles leak no fd") {
            let l = try await net.listen(port: 0)
            defer { l.close() }
            let base = openDescriptorCount()
            for _ in 0 ..< 500 {
                async let accepted = l.accept()
                let c = try await net.connect(host: "127.0.0.1", port: l.port, timeout: 2)
                let s = try await accepted
                try await c.write(Data([7]))
                _ = try await s.read(exactly: 1)
                c.close()
                s.close()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            let after = openDescriptorCount()
            if let base, let after { try check(after <= base + 1, "fds \(base) → \(after)") }
            return "fds \(base.map(String.init) ?? "?") → \(after.map(String.init) ?? "?")"
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let fdAfter = openDescriptorCount()
        print("open fds: \(fdBefore.map(String.init) ?? "?") before, \(fdAfter.map(String.init) ?? "?") after")
        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}

#if canImport(Darwin)
private let SOCK_STREAM_VALUE = SOCK_STREAM
#else
private let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#endif
