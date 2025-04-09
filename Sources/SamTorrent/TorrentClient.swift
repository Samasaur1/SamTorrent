import Foundation
import FlyingSocks
import BencodeKit
import Crypto

let BIND_ADDRESS = "0.0.0.0"

struct PieceRequest {
    let index: UInt32
    let offset: UInt32
    let length: UInt32
}

public actor TorrentClient {
    public let peerID: PeerID
    public private(set) var torrents: [InfoHash: Torrent]
    private(set) var port: UInt16 = 0

    internal let pool: some AsyncSocketPool = .make()

    public init() {
        self.peerID = PeerID.random()
        self.torrents = [:]
        Logger.shared.log("We support \(ExtensionData.supportedByMe)", type: .setup)
    }

    public func launch() async throws {
        Logger.shared.log("preparing pool", type: .setup)
        try await pool.prepare()
        Logger.shared.log("creating socket", type: .setup)
        let _socket = try Socket(domain: AF_INET, type: .stream)
        Logger.shared.log("disabling SIGPIPE", type: .setup)
        try _socket.setValue(true, for: .noSIGPIPE)
        Logger.shared.log("binding to address", type: .setup)
        var bound = false
        for potentialPort in UInt16(54321)...54329 {
            do {
                try _socket.bind(to: .inet(ip4: BIND_ADDRESS, port: potentialPort))
                Logger.shared.log("Bound to port \(potentialPort)", type: .setup)
                bound = true
                port = potentialPort
                break
            } catch let error as SocketError {
                switch error {
                case let .failed(type, errno, message):
                    if errno == EADDRINUSE {
                        Logger.shared.warn("Failed to bind to potential port \(potentialPort) (in use)", type: .setup)
                        continue
                    }
                    Logger.shared.error("\(type) \(message) (\(errno))", type: .setup)
                default:
                    Logger.shared.error("Cannot bind to port: \(error)", type: .setup)
                }
                exit(2)
            }
        }
        if !bound {
            Logger.shared.error("Unable to bind to any port", type: .setup)
            exit(2)
        }
        Logger.shared.log("listening", type: .setup)
        do {
            try _socket.listen()
        } catch {
            Logger.shared.error("Unable to listen (error: \(error))", type: .setup)
            exit(2)
        }
        Logger.shared.log("creating async socket", type: .setup)
        let serverSocket = try AsyncSocket(socket: _socket, pool: pool)

        Logger.shared.log("setup complete", type: .setup)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.pool.run()
            }
            group.addTask {
                try await withThrowingDiscardingTaskGroup { group in
                    for try await _conn in serverSocket.sockets {
                        Logger.shared.log("Got incoming connection", type: .incomingConnections)
                        group.addTask {
                            let conn = try await PeerConnection.incoming(wrapping: _conn, asPartOf: self)
                            defer { try? conn.close() }
                            do {
                                try await conn.runP2P()
                                Logger.shared.log("[\(conn)] closed gracefully", type: .incomingConnections)
                            } catch {
                                Logger.shared.warn("[\(conn)] closed with error \(error)", type: .incomingConnections)
                                throw error
                            }
                        }
                    }
                }
                throw SocketError.disconnected
            }
            try await group.next()
        }
    }

    internal func makeConnection(to peerID: PeerID, at address: SocketAddress, for torrent: Torrent) async throws {
        let conn = try await PeerConnection.outgoing(to: peerID, at: address, for: torrent, asPartOf: self)
        defer { try? conn.close() }
        do {
            try await conn.runP2P()
            Logger.shared.log("[\(conn)] closed gracefully", type: .outgoingConnections)
        } catch {
            Logger.shared.warn("[\(conn)] closed with error \(error)", type: .outgoingConnections)
            throw error
        }
    }

    // TODO: make public
    // TODO: this should probably take a file and not a TorrentFile object
    public func addTorrent(from tf: TorrentFileV1) throws {
        let infoDictEncoded = try BencodeEncoder().encode(tf.info)
        let ih = Data(Insecure.SHA1.hash(data: infoDictEncoded))
        let infoHash = InfoHash.v1(ih)
        self.torrents[infoHash] = Torrent(infoHash: infoHash, torrentFile: tf, client: self, peerID: self.peerID, port: self.port)
    }
}
