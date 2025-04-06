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
    let peerID: PeerID
    public private(set) var torrents: [InfoHash: Torrent]
    private(set) var port: UInt16 = 0

    private let pool: some AsyncSocketPool = .make()

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
                        var conn = PeerConnection(wrapping: _conn)
                        Logger.shared.log("Got incoming connection \(conn)", type: .incomingConnections)
                        group.addTask {
                            defer { try? conn.close() }
                            do {
                                try await self.accept(connection: &conn)
                                Logger.shared.log("Connection \(conn) closed gracefully", type: .incomingConnections)
                            } catch {
                                Logger.shared.warn("Connection \(conn) closed with error: \(error)", type: .incomingConnections)
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

    // TODO: make public
    // TODO: this should probably take a file and not a TorrentFile object
    public func addTorrent(from tf: TorrentFileV1) throws {
        let infoDictEncoded = try BencodeEncoder().encode(tf.info)
        let ih = Data(Insecure.SHA1.hash(data: infoDictEncoded))
        let infoHash = InfoHash.v1(ih)
        self.torrents[infoHash] = Torrent(infoHash: infoHash, torrentFile: tf, client: self, peerID: self.peerID, port: self.port)
    }

    private func accept(connection: inout PeerConnection) async throws {
        // TODO: possibly need to start our part of the handshake immediately after reading the info hash
        let infoHash: InfoHash
        do {
            (_, infoHash, connection.peerID) = try await readIncomingHandshake(on: connection)
            Logger.shared.log("Read incoming handshake for incoming connection \(connection)", type: .incomingConnections)
        } catch {
            Logger.shared.warn("Unable to read incoming handshake for incoming connection \(connection)", type: .incomingConnections)
            throw error
        }

        guard let torrent = self.torrents[infoHash] else {
            Logger.shared.warn("Incoming connection \(connection) wants to paricipate in a torrent that we aren't participating in", type: .incomingConnections)
            throw TorrentError.wrongInfoHash(infoHash)
        }

        guard await torrent.isRunning else {
            Logger.shared.warn("Incoming connection \(connection) wants to participate in a torrent that we have paused", type: .incomingConnections)
            throw TorrentError.pausedTorrent(infoHash)
        }

        do {
            try await writeOutgoingHandshake(for: infoHash, with: self.peerID, on: connection)
            Logger.shared.log("Wrote outgoing handshake for incoming connection \(connection)", type: .incomingConnections)
        } catch {
            Logger.shared.warn("Unable to write outgoing handshake for incoming connection \(connection)", type: .incomingConnections)
            throw error
        }

        do {
            try await self.postHandshake(for: torrent, on: connection)
        } catch {
            Logger.shared.warn("P2P communication with \(connection) exited with an error", type: .incomingConnections)
            throw error
        }
    }

    internal func makeConnection(to peerID: PeerID, at address: SocketAddress, for torrent: Torrent) {
        let uuid = UUID()
        let addrString: String
        do {
            addrString = try address.toString()
        } catch {
            addrString = String(describing: address)
        }
        Task {
            do {
                Logger.shared.log("Attempting to connect to \(addrString) (will be connection \(uuid.uuidString))", type: .outgoingConnections)
                var connection: PeerConnection
                do {
                    let socket = try await AsyncSocket.connected(to: address, pool: self.pool)
                    connection = PeerConnection(wrapping: socket, with: uuid)
                    Logger.shared.log("Connected to \(addrString) on connection \(connection)", type: .outgoingConnections)
                } catch {
                    Logger.shared.warn("Unable to connect to \(addrString) (error: \(error))", type: .outgoingConnections)
                    throw error
                }
                defer { try? connection.close() }

                let infoHash = torrent.infoHash

                do {
                    try await writeOutgoingHandshake(for: infoHash, with: self.peerID, on: connection)
                    Logger.shared.log("Wrote outgoing handshake for outgoing connection \(connection)", type: .outgoingConnections)
                } catch {
                    Logger.shared.warn("Unable to write outgoing handshake for outgoing connection \(connection)", type: .outgoingConnections)
                    throw error
                }

                let theirInfoHash: InfoHash
                do {
                    (_, theirInfoHash, connection.peerID) = try await readIncomingHandshake(on: connection)
                    Logger.shared.log("Read incoming handshake for outgoing connection \(connection)", type: .outgoingConnections)
                } catch {
                    Logger.shared.warn("Unable to read incoming handshake for outgoing connection \(connection)", type: .outgoingConnections)
                    throw error
                }

                guard infoHash == theirInfoHash else {
                    Logger.shared.warn("Connection \(connection) has incorrect info hash \(theirInfoHash) (expected \(infoHash))", type: .outgoingConnections)
                    throw TorrentError.wrongInfoHash(theirInfoHash)
                }

                do {
                    try await self.postHandshake(for: torrent, on: connection)
                } catch {
                    Logger.shared.warn("P2P communication with \(connection) exited with an error", type: .outgoingConnections)
                    throw error
                }
            } catch {
                Logger.shared.warn("Connection \(uuid.uuidString) closed with error: \(error)", type: .outgoingConnections)
                throw error
            }
            Logger.shared.log("Connection \(uuid.uuidString) closed gracefully", type: .outgoingConnections)
        }
    }

    private func readIncomingHandshake(on connection: PeerConnection) async throws -> (ExtensionData, InfoHash, PeerID) {
        let protocolLength: Int
        do {
            protocolLength = try await Int(connection.read(bytes: 1)[0])
            Logger.shared.log("Connection \(connection) had a \(protocolLength) byte protocol name", type: .handshakes)
        } catch {
            Logger.shared.warn("Connection \(connection) was unable to read protcol length", type: .handshakes)
            throw error
        }
        let protocolBytes = try await connection.read(bytes: protocolLength)
        guard let protocolName = String(bytes: protocolBytes, encoding: .ascii) else {
            Logger.shared.error("Cannot decode P2P protocol name (i.e., it is non-ASCII) on connection \(connection)", type: .handshakes)
            throw TorrentError.nonASCIIProtocol(Data(protocolBytes))
        }
        Logger.shared.log("Connection \(connection) wants to use protocol: \(protocolName)", type: .handshakes)
        guard protocolName == "BitTorrent protocol" else {
            Logger.shared.error("Connection \(connection)'s desired P2P protocol is '\(protocolName)', not 'BitTorrent protocol'", type: .handshakes)
            throw TorrentError.unknownProtocol(protocolName)
        }

        let extensionDataRaw = try await connection.read(bytes: 8)
        Logger.shared.log("Connection \(connection) has raw extension data: \(extensionDataRaw.hexEncodedString())", type: .handshakes)
        let extensionData = ExtensionData(from: extensionDataRaw)
        Logger.shared.log("Connection \(connection) has extension data: \(extensionData)", type: .handshakes)

        let infoHashRaw = try await connection.read(bytes: 20)
        Logger.shared.log("Connection \(connection) has raw info hash: \(infoHashRaw.hexEncodedString())", type: .handshakes)
        let infoHash = InfoHash.v1(Data(infoHashRaw))
        Logger.shared.log("Connection \(connection) has info hash: \(infoHash)", type: .handshakes)

        let peerIDRaw = try await connection.read(bytes: 20)
        Logger.shared.log("Connection \(connection) has raw peer ID: \(peerIDRaw.hexEncodedString())", type: .handshakes)
        let peerID = PeerID(bytes: Data(peerIDRaw))
        Logger.shared.log("Connection \(connection) has peer ID: \(peerID)", type: .handshakes)

        return (extensionData, infoHash, peerID)
    }

    private func writeOutgoingHandshake(for infoHash: InfoHash, with peerID: PeerID, on connection: PeerConnection) async throws {
        var data = Data([UInt8(19)])
        data.append("BitTorrent protocol".data(using: .ascii)!)

        data.append(ExtensionData.supportedByMe.bytes)

        data.append(infoHash.bytes)

        data.append(peerID.bytes)

        Logger.shared.log("Writing outgoing handshake with infoHash \(infoHash) to connection \(connection)", type: .handshakes)
        try await connection.write(data)
    }

    private func postHandshake(for torrent: Torrent, on connection: PeerConnection) async throws {
        // TODO: implement peer wire protocol
        let torrentFile = await torrent.torrentFile
        try await withThrowingTaskGroup { group in
            // All connections start like this
            var peerChoking = true
            var peerInterested = false
            var usChoking = true
            var usInterested = false

            // Assume empty; overwrite if we get a bitfield message
            var peerHaves: Haves = Haves.empty(ofLength: torrentFile.pieceCount)

            // This lets us detect the error where a peer sends a bitfield as not the first message
            var hasReceivedFirstMessage = false

            var localHavesCopy = await torrent.haves
            Logger.shared.log("Writing initial bitfield (\(localHavesCopy.percentComplete, stringFormat: "%.2f")% of file) to connection \(connection)", type: .peerCommunication)
            async let x: Void = connection.write(localHavesCopy.makeMessage())
            try await x
            

            group.addTask {
                while await torrent.isRunning {
                    let messageLengthData = try await connection.read(bytes: 4)
                    let messageLength = UInt32(bigEndian: Data(messageLengthData).to(type: UInt32.self)!)
                    guard messageLength > 0 else {
                        // This message is a keep-alive; ignore it
                        continue
                    }
                    let messageData = try await connection.read(bytes: Int(messageLength))
                    defer { hasReceivedFirstMessage = true }

                    switch messageData[0] {
                    case 0:
                        // choke
                        peerChoking = true
                        Logger.shared.log("Peer \(connection) is now choking us", type: .peerCommunication)
                    case 1:
                        // unchoke
                        peerChoking = false
                        Logger.shared.log("Peer \(connection) is no longer choking us", type: .peerCommunication)
                    case 2:
                        // interested
                        peerInterested = true
                        Logger.shared.log("Peer \(connection) is now interested in us", type: .peerCommunication)
                    case 3:
                        // not interested
                        peerInterested = false
                        Logger.shared.log("Peer \(connection) is no longer interested in us", type: .peerCommunication)
                    case 4:
                        // have
                        let index = UInt32(bigEndian: Data(messageData[1...]).to(type: UInt32.self)!)
                        peerHaves[index] = true
                        Logger.shared.log("Peer \(connection) now has piece \(index)", type: .peerCommunication)
                        // TODO: perhaps kick off another request
                    case 5:
                        // bitfield
                        if hasReceivedFirstMessage {
                            // The original BitTorrent spec (BEP0003) just says "'bitfield' is only ever sent as the first message."
                            // It doesn't clarify what clients should do if this is violated, but based on other BEPs I believe that
                            //   clients are supposed to close the connection.
                            Logger.shared.warn("Peer \(connection) send bitfield after already sending messages", type: .peerCommunication)
                            throw TorrentError.bitfieldAfterStart
                        }
                        let bitfield = Data(messageData[1...])
                        peerHaves = Haves(fromBitfield: bitfield, length: peerHaves.length)
                        Logger.shared.log("Peer \(connection) sent bitfield (has \(localHavesCopy.percentComplete, stringFormat: "%.2f")% of the file)", type: .peerCommunication)
                    case 6:
                        // request
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("Peer \(connection) requested \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
                        let req = PieceRequest(index: index, offset: begin, length: length)
                        // TODO: build request and add to set
                    case 7:
                        // piece
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let piece = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("Peer \(connection) sent piece (chunk?) at offset \(begin) of piece \(index)", type: .peerCommunication)
                        // TODO: handle piece
                    case 8:
                        // cancel
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("Peer \(connection) canceled previous request for \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
                        let req = PieceRequest(index: index, offset: begin, length: length)
                        // TODO: build request and remove from set
                    // BEP0005 (DHT PROTOCOL)
                    case 9:
                        // port
                        guard ExtensionData.supportedByMe.contains(.dht) else {
                            Logger.shared.warn("Got P2P message that requires the DHT protocol (BEP 5), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                    // END BEP0005 (DHT PROTOCOL)
                    // BEP0006 FAST EXTENSION
                    case 0x0D:
                        // suggest piece
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }
                    case 0x0E:
                        // have all
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        if hasReceivedFirstMessage {
                            Logger.shared.warn("Peer \(connection) sent haveAll after already sending messages", type: .peerCommunication)
                            throw TorrentError.bitfieldAfterStart
                        }
                        peerHaves = Haves.full(ofLength: peerHaves.length)
                    case 0x0F:
                        // have none
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        if hasReceivedFirstMessage {
                            Logger.shared.warn("Peer \(connection) sent haveNone after already sending messages", type: .peerCommunication)
                            throw TorrentError.bitfieldAfterStart
                        }
                        peerHaves = Haves.empty(ofLength: peerHaves.length)
                    case 0x10:
                        // reject request
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }
                    case 0x11:
                        // allowed fast
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }
                    // END BEP0006 FAST EXTENSION
                    default:
                        Logger.shared.warn("Unknown message type from peer \(connection)", type: .peerCommunication)
                        try connection.close()
                        // unknown message type
                    }
                }
            }
            group.addTask {
                while await torrent.isRunning {
                    try await Task.sleep(for: .seconds(1))
                }
            }
            try await group.next()
        }
        // while await torrent.isRunning {
        //     try await Task.sleep(for: .seconds(1))
        //     try await connection.write("Hello\n".data(using: .ascii)!)
        // }
    }
}
