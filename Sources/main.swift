import Foundation
import FlyingSocks
import BencodeKit
import Crypto

struct ExtensionData: OptionSet {
    let rawValue: UInt64

    static let dht: ExtensionData = ExtensionData(rawValue: 1 << 0) // BEP0005
    static let fast: ExtensionData = ExtensionData(rawValue: 1 << 2) // BEP0006
    static let `extension`: ExtensionData = ExtensionData(rawValue: 1 << 20) //BEP0010

    static let supportedByMe: ExtensionData = []
}
extension ExtensionData: CustomStringConvertible {
    init(from bytes: Data) {
        rawValue = bytes.to(type: UInt64.self)!
        // TODO: test this
    }

    var bytes: Data {
        Data(from: self.rawValue)
        // TODO: test this
    }

    var description: String {
        "ExtensionData(dht: \(self.contains(.dht)), fast: \(self.contains(.fast)), extension: \(self.contains(.extension)))"
    }
}

public enum InfoHash: Hashable, Sendable, CustomStringConvertible {
    case v1(Data)

    public var description: String {
        switch self {
        case .v1(let data):
            return data.hexEncodedString()
        }
    }

    var bytes: Data {
        switch self {
        case .v1(let data):
            return data
        }
    }

    func percentEncoded() -> String {
        bytes.percentEncoded()
    }
}


struct PeerID: CustomStringConvertible {
    static func random() -> PeerID {
        let versionData = "-SG0100-".data(using: .ascii)!
        let randomData = Data((0..<12).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let data = versionData + randomData
        return PeerID(bytes: data)
    }

    var bytes: Data

    var description: String {
        let chars = bytes.map { byte in
            Character(UnicodeScalar(byte))
        }
        return String(chars)
    }

    func percentEncoded() -> String {
        bytes.percentEncoded()
    }
}

public struct Connection: Sendable, CustomStringConvertible {
    let uuid: UUID
    var peerID: PeerID! = nil

    let socket: AsyncSocket

    init(wrapping socket: AsyncSocket, with uuid: UUID = UUID()) {
        self.socket = socket
        self.uuid = uuid
    }

    public var description: String {
        return if let p = peerID {
            "\(uuid.uuidString) (\(p))"
        } else {
            uuid.uuidString
        }
    }

    func close() throws {
        try socket.close()
    }
    func read(bytes: Int) async throws -> Data {
        let arr = try await self.socket.read(bytes: bytes)
        // TODO: use Data(bytesNoCopy:count:deallocator:) ?
        return Data(arr)
    }
    func write(_ data: Data) async throws {
        try await self.socket.write(data)
    }
}

public actor TorrentClient {
    let peerID: PeerID
    var torrents: [InfoHash: Torrent]
    var port: UInt16 = 0

    private let pool: some AsyncSocketPool = .make()

    init() {
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
                        var conn = Connection(wrapping: _conn)
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
    /* public */ func addTorrent(from tf: TorrentFileV1) throws {
        let infoDictEncoded = try BencodeEncoder().encode(tf.info)
        let ih = Data(Insecure.SHA1.hash(data: infoDictEncoded))
        let infoHash = InfoHash.v1(ih)
        self.torrents[infoHash] = Torrent(infoHash: infoHash, torrentFile: tf, peerID: self.peerID, port: self.port)
    }

    private func accept(connection: inout Connection) async throws {
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
                var connection: Connection
                do {
                    let socket = try await AsyncSocket.connected(to: address, pool: self.pool)
                    connection = Connection(wrapping: socket, with: uuid)
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

    private func readIncomingHandshake(on connection: Connection) async throws -> (ExtensionData, InfoHash, PeerID) {
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

    private func writeOutgoingHandshake(for infoHash: InfoHash, with peerID: PeerID, on connection: Connection) async throws {
        var data = Data([UInt8(19)])
        data.append("BitTorrent protocol".data(using: .ascii)!)

        data.append(ExtensionData.supportedByMe.bytes)

        data.append(infoHash.bytes)

        data.append(peerID.bytes)

        Logger.shared.log("Writing outgoing handshake with infoHash \(infoHash) to connection \(connection)", type: .handshakes)
        try await connection.write(data)
    }

    private func postHandshake(for torrent: Torrent, on connection: Connection) async throws {
        // TODO: implement peer wire protocol
        let torrentFile = torrent.torrentFile
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
                            try connection.close()
                            return // TODO: return or something else?
                            // TODO: don't close connection. yes throw error
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
                        // TODO: build request and add to set
                    case 7:
                        // piece
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let piece = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("Peer \(connection) send piece (chunk?) at offset \(begin) of piece \(index)", type: .peerCommunication)
                        // TODO: handle piece
                    case 8:
                        // cancel
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("Peer \(connection) canceled previous request for \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
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
                            try connection.close()
                        }
                        peerHaves = Haves.full(ofLength: peerHaves.length)
                    case 0x0F:
                        // have none
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        if hasReceivedFirstMessage {
                            try connection.close()
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
//
// extension TorrentClient {
//     func __addTorrentBy(infoHash: InfoHash) {
//         self.torrents[infoHash] = Torrent(infoHash: infoHash)
//     }
// }

struct FailedTrackerResponse: Codable {
    let failureReason: String

    enum CodingKeys: String, CodingKey {
        case failureReason = "failure reason"
    }
}
struct TrackerResponse: Codable {
    let interval: Int
    let trackerID: String?
    let complete: Int
    let incomplete: Int
    let peers: [PeerInfo] //TODO: support compact binary model as well. custom decode function?

    enum CodingKeys: String, CodingKey {
        case interval, complete, incomplete, peers
        case trackerID = "tracker id"
    }
}
struct PeerInfo: Codable {
    let peerID: Data
    let ip: String
    let port: UInt16

    enum CodingKeys: String, CodingKey {
        case ip, port
        case peerID = "peer id"
    }
}

let BIND_ADDRESS = "0.0.0.0"

public actor Torrent {
    public var isRunning: Bool = false {
        didSet {
            // TODO: convert to logger
            print("torrent with infohash \(self.infoHash) isRunning didSet")
            // Check that the value actually changed
            guard oldValue != isRunning else { return }

            trackerTask?.cancel()

            // Send start or stop tracker requests
            Task {
                try await performTrackerRequest(for: isRunning ? .start : .stop)
            }
        }
    }
    public let infoHash: InfoHash
    let torrentFile: TorrentFileV1
    let peerID: PeerID
    let port: UInt16

    // TODO: better way to pass the peer ID around?
    init(infoHash: InfoHash, torrentFile: TorrentFileV1, peerID: PeerID, port: UInt16) {
        self.infoHash = infoHash
        self.torrentFile = torrentFile
        self.peerID = peerID
        self.port = port
        self.haves = Haves.empty(ofLength: torrentFile.pieceCount)
    }

    private enum Event: String {
        case start = "started"
        case stop = "stopped"
        case complete = "completed"
        case periodic = "empty"
    }

    private func buildTrackerRequest(for event: Event) throws -> URLRequest {
        Logger.shared.log("Building tracker request for \(event)", type: .trackerRequests)
        // TODO: handle picking the correct tracker
        guard var components = URLComponents(string: self.torrentFile.announce) else {
            Logger.shared.error("Cannot construct URLComponents from announce URL", type: .trackerRequests)
            throw TorrentError.invalidAnnounceURL(self.torrentFile.announce)
        }
        components.queryItems = [
            URLQueryItem(name: "port", value: String(self.port)),
            URLQueryItem(name: "uploaded", value: String(self.uploaded)),
            URLQueryItem(name: "downloaded", value: String(self.downloaded)),
            URLQueryItem(name: "left", value: String(self.left)),
        ]
        if event != .periodic {
            components.queryItems?.append(URLQueryItem(name: "event", value: event.rawValue))
        }
        if let trackerID = self.trackerID {
            // TODO: more logging?
            components.queryItems?.append(URLQueryItem(name: "trackerid", value: trackerID))
        }
        components.percentEncodedQueryItems?.append(contentsOf: [
            URLQueryItem(name: "info_hash", value: self.infoHash.percentEncoded()),
            URLQueryItem(name: "peer_id", value: self.peerID.percentEncoded()),
        ])
        guard let url = components.url else {
            Logger.shared.error("Cannot build URL from components", type: .trackerRequests)
            fatalError()
        }
        Logger.shared.log("Built URL \(url)", type: .trackerRequests)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    private func performTrackerRequest(for event: Event) async throws {
        Logger.shared.log("Performing tracker request for \(event)", type: .trackerRequests)
        let req = try buildTrackerRequest(for: event)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            Logger.shared.error("Tracker request failed with error: \(error)", type: .trackerRequests)
            fatalError("This shouldn't be an error at the end, but is for now")
        }

        guard let resp = resp as? HTTPURLResponse else {
            Logger.shared.error("Invalid (non-HTTP) \(event) tracker response", type: .trackerRequests)
            fatalError("Invalid tracker response to \(event) event")
        }

        guard resp.statusCode == 200 else {
            //TODO: also have to handle swapping trackers here
            Logger.shared.error("Non-200 \(event) tracker response", type: .trackerRequests)
            fatalError()
        }

        if let obj = try? BencodeDecoder().decode(FailedTrackerResponse.self, from: data) {
            Logger.shared.error("\(event) tracker request failed with error: \(obj.failureReason)", type: .trackerRequests)
            fatalError("Tracker request failed with error: \(obj.failureReason)")
        }

        guard let obj = try? BencodeDecoder().decode(TrackerResponse.self, from: data) else {
            Logger.shared.error("Cannot decode \(event) tracker response", type: .trackerRequests)
            fatalError()
        }

        Logger.shared.log("Tracker response: \(obj.complete) complete, \(obj.incomplete) incomplete, \(obj.peers.count) peers (first peer \(obj.peers.first?.ip):\(obj.peers.first?.port))", type: .trackerRequests)
        obj.peers.prefix(upTo: 5).map { peerInfo in
            let peerID = PeerID(bytes: peerInfo.peerID)

            let addr: SocketAddress
            do {
                addr = try .inet(ip4: peerInfo.ip, port: peerInfo.port)
                Logger.shared.log("Created IPv4 SocketAddress for peer \(peerID)", type: .outgoingConnections)
            } catch {
                do {
                    addr = try .inet6(ip6: peerInfo.ip, port: peerInfo.port)
                    Logger.shared.log("Created IPv6 SocketAddress for peer \(peerID)", type: .outgoingConnections)
                } catch {
                    Logger.shared.warn("Unable to create SocketAddress for peer \(peerID)", type: .outgoingConnections)
                    return
                }
            }
            Task {
                await client.makeConnection(to: peerID, at: addr, for: self)
            }
        }

        if let trackerID = obj.trackerID {
            Logger.shared.log("Tracker ID now set to \(trackerID)", type: .trackerRequests)
            self.trackerID = trackerID
        }

        if event == .start || event == .periodic {
            self.trackerTask?.cancel()
            self.trackerTask = Task {
                Logger.shared.log("Sleeping for \(obj.interval) seconds before next periodic request", type: .trackerRequests)
                try await Task.sleep(for: .seconds(obj.interval))
                try await performTrackerRequest(for: .periodic)
            }
        }
    }

    var uploaded: Int = 0
    var downloaded: Int = 0
    var left: Int {
        0
    }

    private var trackerID: String?

    var haves: Haves

    private var trackerTask: Task<Void, Error>? = nil

    public func pause() {
        self.isRunning = false
    }

    public func resume() {
        self.isRunning = true
    }
}

enum TorrentError: Error {
    case nonASCIIProtocol(Data)
    case unknownProtocol(String)
    case wrongInfoHash(InfoHash)
    case invalidAnnounceURL(String)
    case pausedTorrent(InfoHash)
    case unsupportedExtension(BEP: Int?)
}

let client = TorrentClient()

let ioTask = Task {
    if #available(macOS 12.0, *) {
        var it = FileHandle.standardInput.bytes.lines.makeAsyncIterator()
        print("made asynciterator")
        while true {
            guard let line = try? await it.next() else { break }
            print("got line")
            var lit = line.split(separator: " ").makeIterator()
            switch lit.next() {
            case "torrentfile":
                let path = lit.joined(separator: " ")
                print("Loading torrent from metainfo file at '\(path)'")
                guard let url = URL(string: path) else {
                    print("cannot construct URL from path")
                    continue
                }
                print("converted path to URL \(url)")
                print("file at path \(url.path) exists: \(FileManager.default.fileExists(atPath: url.path))")
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    print("cannot load torrent file")
                    continue
                }
                guard let tf = try? BencodeDecoder().decode(TorrentFileV1.self, from: data) else {
                    print("cannot decode torrent file")
                    continue
                }
                try await client.addTorrent(from: tf)
            // case "infohash":
            //     guard let hash = lit.next() else { continue }
            //     let data = hash.data(using: .utf8)!
            //     guard data.count == 20 else { print("info hash wrong length (was \(data.count), must be 20)"); continue }
            //     let infoHash = InfoHash.v1(data)
            //     await client.__addTorrentBy(infoHash: infoHash)
            //     print("started torrent with info hash \(infoHash)")
            case "list":
                print("client has torrents with info hashes:")
                for (ih, t) in await client.torrents {
                    print("- \(ih) (\(await t.isRunning ? "running" : "not running"))")
                }
            case "resume":
                guard let hash = lit.next() else { continue }
                let data = hash.data(using: .utf8)!
                guard data.count == 20 else { print("info hash wrong length (was \(data.count), must be 20)"); continue }
                let infoHash = InfoHash.v1(data)
                await client.torrents[infoHash]?.resume()
                print("resuming torrent with info hash \(infoHash)")
            case "pause":
                guard let hash = lit.next() else { continue }
                let data = hash.data(using: .utf8)!
                guard data.count == 20 else { print("info hash wrong length (was \(data.count), must be 20)"); continue }
                let infoHash = InfoHash.v1(data)
                await client.torrents[infoHash]?.pause()
                print("pausing torrent with info hash \(infoHash)")
            case "resumeall":
                await withTaskGroup(of: Void.self) { group in
                    for (infoHash, torrent) in await client.torrents {
                        group.addTask {
                            await torrent.resume()
                            print("\(infoHash) resumed")
                        }
                    }
                }
            case "pauseall":
                await withTaskGroup(of: Void.self) { group in
                    for (infoHash, torrent) in await client.torrents {
                        group.addTask {
                            await torrent.pause()
                            print("\(infoHash) paused")
                        }
                    }
                }
            case "connectto":
                await client.makeConnection(to: PeerID.random(), at: try! .inet(ip4: "127.0.0.1", port: 12345), for: client.torrents.first!.value)
            default:
                print("unknown command")
                continue
            }
                // switch try await conn.read(bytes: 1)[0] {
                // case UInt8(ascii: "T"): //torrent
                //     let _infoHash = try await conn.read(bytes: 20)
                //     let infoHash = InfoHash.v1(Data(_infoHash))
                //     await client.start(torrent: infoHash)
                //     try await conn.write("Starting torrent \(infoHash)".data(using: .utf8)!)
                //     print("Starting torrent \(infoHash)")
                // case UInt8(ascii: "G"): //go
                //     await client.resumeAll()
                //     try await conn.write("Resuming all torrents".data(using: .utf8)!)
                //     print("Resuming all torrents")
                // case UInt8(ascii: "S"): //stop
                //     await client.pauseAll()
                //     try await conn.write("Pausing all torrents".data(using: .utf8)!)
                //     print("Pausing all torrents")
                // case UInt8(ascii: "P"): //pause
                //     let _infoHash = try await conn.read(bytes: 20)
                //     let infoHash = InfoHash.v1(Data(_infoHash))
                //     await client.pause(torrent: infoHash)
                //     try await conn.write("Pausing torrent \(infoHash)".data(using: .utf8)!)
                //     print("Pausing torrent \(infoHash)")
                // case UInt8(ascii: "R"): //resume
                //     let _infoHash = try await conn.read(bytes: 20)
                //     let infoHash = InfoHash.v1(Data(_infoHash))
                //     await client.resume(torrent: infoHash)
                //     try await conn.write("Resuming torrent \(infoHash)".data(using: .utf8)!)
                //     print("Resuming torrent \(infoHash)")
                // default:
                //     try await conn.write("Unknown control command".data(using: .utf8)!)
                //     print("Unknown control command")
                // }
        }
    }
}

try await client.launch()
