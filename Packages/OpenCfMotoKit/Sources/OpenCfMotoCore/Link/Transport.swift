// SPDX-License-Identifier: AGPL-3.0-or-later
// Transport abstraction used by the PXC link. The production implementation is
// `POSIXNetworkProvider` (BSD sockets, Link/POSIXTransport.swift); `NWNetworkProvider`
// (Network.framework, OpenCfMotoApple) is kept for reference. Tests use in-memory pipes or the
// POSIX provider on loopback. The protocol code never touches sockets directly.

import Foundation

public enum TransportError: Error, Equatable, CustomStringConvertible {
    /// The peer closed the connection (EOF) or the stream was closed locally.
    case closed
    case timeout
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .closed: return "connection closed"
        case .timeout: return "timed out"
        case .cancelled: return "cancelled"
        case let .failed(m): return "transport failure: \(m)"
        }
    }
}

/// A bidirectional, ordered byte stream (a TCP connection).
/// Implementations must be safe to call from concurrent tasks: one reader task and one writer
/// task at a time per stream (writes must be serialized internally, in call order).
/// `close()` must make any pending `read`/`write` throw promptly.
public protocol ByteStream: AnyObject, Sendable {
    /// e.g. "192.168.0.1:41234" — for logs.
    var remoteEndpoint: String { get }
    /// Remote IPv4/IPv6 host (no port), if known.
    var remoteHost: String? { get }
    /// The local port of this connection (for accepted connections: the listener's port).
    var localPort: UInt16 { get }

    /// Reads exactly `count` bytes. Throws `TransportError.closed` on EOF before `count` bytes.
    func read(exactly count: Int) async throws -> Data
    /// Reads between 1 and `maxCount` bytes (whatever is available). Throws `.closed` on EOF.
    func readSome(maxCount: Int) async throws -> Data
    /// Writes all bytes (completes when handed to the OS send buffer).
    func write(_ data: Data) async throws
    func close()
}

/// A listening TCP socket on a fixed port (all local interfaces).
public protocol StreamListener: AnyObject, Sendable {
    var port: UInt16 { get }
    /// Waits for the next inbound connection. Throws `TransportError.closed` once closed.
    func accept() async throws -> any ByteStream
    func close()
}

public protocol NetworkProvider: Sendable {
    /// Starts listening on `port`. Throws if the port cannot be bound.
    func listen(port: UInt16) async throws -> any StreamListener
    /// Opens an outbound TCP connection. Throws `TransportError.timeout` after `timeout` seconds.
    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> any ByteStream
}

/// Text conventions of the `TransportError.failed` messages of the platform transports
/// (`POSIXNetworkProvider`, `NWNetworkProvider`), so callers classify failures by text.
public enum PlatformTransportErrors {
    /// Prefix of the listen failure when another process holds the port (EADDRINUSE: typically the
    /// official CFMoto / Carbit app, or our own ReplayKit extension). The link maps it to
    /// `LinkFailure.portInUse(port)`.
    public static let addressInUsePrefix = "EADDRINUSE"
    /// Exact message thrown when iOS Local Network privacy blocks a connection.
    public static let localNetworkDenied = "localNetworkDenied"
    /// Prefix of the message thrown when the peer refused the TCP connection.
    public static let connectionRefusedPrefix = "ECONNREFUSED"

    public static func addressInUse(port: UInt16) -> TransportError {
        .failed("\(addressInUsePrefix): address already in use (port \(port))")
    }

    public static var localNetworkDeniedError: TransportError { .failed(localNetworkDenied) }

    /// True for the EADDRINUSE listen failure.
    public static func isAddressInUse(_ error: Error) -> Bool {
        guard case let .failed(m)? = error as? TransportError else { return false }
        return m.hasPrefix(addressInUsePrefix)
    }

    /// True for a Local Network privacy denial.
    public static func isLocalNetworkDenied(_ error: Error) -> Bool {
        guard case let .failed(m)? = error as? TransportError else { return false }
        return m == localNetworkDenied
    }

    /// True for a refused connection.
    public static func isConnectionRefused(_ error: Error) -> Bool {
        guard case let .failed(m)? = error as? TransportError else { return false }
        return m.hasPrefix(connectionRefusedPrefix)
    }
}
