import Foundation
import FlyingSocks

public struct PeerConnection: Sendable, CustomStringConvertible {
    let uuid: UUID
    let peerID: PeerID
    let infoHash: InfoHash // the info hash of the torrent we're talking with this peer about
    let supportedExtensions: ExtensionData // either [] or nil
    let socket: AsyncSocketWrapper
    let client: TorrentClient
    let torrent: Torrent

    public var description: String {
        "\(uuid.uuidString)/\(peerID)"
    }

    private init(uuid: UUID, peerID: PeerID, infoHash: InfoHash, supportedExtensions: ExtensionData, socket: AsyncSocketWrapper, client: TorrentClient, torrent: Torrent) {
        self.uuid = uuid
        self.peerID = peerID
        self.infoHash = infoHash
        self.supportedExtensions = supportedExtensions
        self.socket = socket
        self.client = client
        self.torrent = torrent
    }

    private static let BITTORRENT_PROTOCOL_NAME = "BitTorrent protocol"

    static func incoming(wrapping _socket: AsyncSocket, asPartOf client: TorrentClient) async throws -> PeerConnection {
        let uuid = UUID()

        let socket = AsyncSocketWrapper(wrapping: _socket)

        let infoHash: InfoHash
        let theirPeerID: PeerID
        let theirSupportedExtensions: ExtensionData
        do {
            (theirSupportedExtensions, infoHash, theirPeerID) = try await Self.readIncomingHandshake(on: socket, uuid: uuid)
            Logger.shared.log("[\(uuid.uuidString)] Read incoming handshake", type: .incomingConnections)
        } catch {
            Logger.shared.warn("[\(uuid.uuidString)] Unable to read incoming handshake (error: \(error))", type: .incomingConnections)
            throw error
        }

        guard let torrent = await client.torrents[infoHash] else {
            Logger.shared.warn("[\(uuid.uuidString)] Connection for unknown torrent", type: .incomingConnections)
            throw TorrentError.wrongInfoHash(infoHash)
        }

        guard await torrent.isRunning else {
            Logger.shared.warn("[\(uuid.uuidString)] Connection for paused torrent", type: .incomingConnections)
            throw TorrentError.pausedTorrent(infoHash)
        }

        do {
            try await Self.writeOutgoingHandshake(for: infoHash, with: client.peerID, on: socket, uuid: uuid)
            Logger.shared.log("[\(uuid.uuidString)] Wrote outgoing handshake", type: .incomingConnections)
        } catch {
            Logger.shared.warn("[\(uuid.uuidString)] Unable to write outgoing handshake (error: \(error))", type: .incomingConnections)
            throw error
        }

        Logger.shared.log("[\(uuid.uuidString)] Handshakes completed", type: .incomingConnections)
        let c = PeerConnection(uuid: uuid, peerID: theirPeerID, infoHash: infoHash, supportedExtensions: theirSupportedExtensions, socket: socket, client: client, torrent: torrent)
        await torrent.add(connection: c)
        return c
    }

    static func outgoing(to peerID: PeerID, at address: SocketAddress, for torrent: Torrent, asPartOf client: TorrentClient) async throws -> PeerConnection {
        let uuid = UUID()
        let addrString: String
        do {
            addrString = try address.toString()
        } catch {
            addrString = String(describing: address)
        }

        do {
            Logger.shared.log("[\(uuid.uuidString)] Attempting to connect to \(addrString)", type: .outgoingConnections)
            let socket: AsyncSocketWrapper
            do {
                socket = try await AsyncSocketWrapper.connected(to: address, pool: client.pool)
                Logger.shared.log("[\(uuid.uuidString)] Connected to \(addrString)", type: .outgoingConnections)
            } catch {
                Logger.shared.warn("[\(uuid.uuidString)] Unable to connect to \(addrString) (error: \(error))", type: .outgoingConnections)
                throw error
            }

            let infoHash = torrent.infoHash
            let ourPeerID = client.peerID

            do {
                try await Self.writeOutgoingHandshake(for: infoHash, with: ourPeerID, on: socket, uuid: uuid)
                Logger.shared.log("[\(uuid.uuidString)] Wrote outgoing handshake", type: .outgoingConnections)
            } catch {
                Logger.shared.warn("[\(uuid.uuidString)] Unable to write outgoing handshake (error: \(error))", type: .outgoingConnections)
                throw error
            }

            let theirInfoHash: InfoHash
            let theirPeerID: PeerID
            let theirSupportedExtensions: ExtensionData
            do {
                (theirSupportedExtensions, theirInfoHash, theirPeerID) = try await Self.readIncomingHandshake(on: socket, uuid: uuid)
                Logger.shared.log("[\(uuid.uuidString)] Read incoming handshake", type: .outgoingConnections)
            } catch {
                Logger.shared.warn("[\(uuid.uuidString)] Unable to read incoming handshake (error: \(error))", type: .outgoingConnections)
                throw error
            }

            guard infoHash == theirInfoHash else {
                Logger.shared.warn("[\(uuid.uuidString)] Incorrect info hash \(theirInfoHash) (expected \(infoHash))", type: .outgoingConnections)
                throw TorrentError.wrongInfoHash(theirInfoHash)
            }

            Logger.shared.log("[\(uuid.uuidString)] Handshakes completed", type: .outgoingConnections)
            let c = PeerConnection(uuid: uuid, peerID: theirPeerID, infoHash: infoHash, supportedExtensions: theirSupportedExtensions, socket: socket, client: client, torrent: torrent)
            await torrent.add(connection: c)
            return c
        } catch {
            Logger.shared.warn("Connection \(uuid.uuidString) closed with error: \(error)", type: .outgoingConnections)
            throw error
        }
    }

    private static func readIncomingHandshake(on socket: AsyncSocketWrapper, uuid: UUID) async throws -> (ExtensionData, InfoHash, PeerID) {
        let protocolLength: Int
        do {
            protocolLength = try await Int(socket.read(bytes: 1)[0])
            Logger.shared.log("[\(uuid.uuidString)] Read a \(protocolLength) byte protocol name", type: .handshakes)
        } catch {
            Logger.shared.warn("[\(uuid.uuidString)] Unable to read protcol length", type: .handshakes)
            throw error
        }
        let protocolBytes = try await socket.read(bytes: protocolLength)
        guard let protocolName = String(bytes: protocolBytes, encoding: .ascii) else {
            Logger.shared.error("[\(uuid.uuidString)] Cannot decode P2P protocol name (i.e., it is non-ASCII)", type: .handshakes)
            throw TorrentError.nonASCIIProtocol(Data(protocolBytes))
        }
        Logger.shared.log("[\(uuid.uuidString)] Connection wants to use protocol: \(protocolName)", type: .handshakes)
        guard protocolName == Self.BITTORRENT_PROTOCOL_NAME else {
            Logger.shared.error("[\(uuid.uuidString)] Desired P2P protocol is '\(protocolName)', not '\(Self.BITTORRENT_PROTOCOL_NAME)'", type: .handshakes)
            throw TorrentError.unknownProtocol(protocolName)
        }

        let extensionDataRaw = try await socket.read(bytes: 8)
        Logger.shared.log("[\(uuid.uuidString)] Raw extension data: \(extensionDataRaw.hexEncodedString())", type: .handshakes)
        let extensionData = ExtensionData(from: extensionDataRaw)
        Logger.shared.log("[\(uuid.uuidString)] Extension data: \(extensionData)", type: .handshakes)

        let infoHashRaw = try await socket.read(bytes: 20)
        Logger.shared.log("[\(uuid.uuidString)] Raw info hash: \(infoHashRaw.hexEncodedString())", type: .handshakes)
        let infoHash = InfoHash.v1(Data(infoHashRaw))
        Logger.shared.log("[\(uuid.uuidString)] Info hash: \(infoHash)", type: .handshakes)

        let peerIDRaw = try await socket.read(bytes: 20)
        Logger.shared.log("[\(uuid.uuidString)] Raw peer ID: \(peerIDRaw.hexEncodedString())", type: .handshakes)
        let peerID = PeerID(bytes: Data(peerIDRaw))
        Logger.shared.log("[\(uuid.uuidString)] Peer ID: \(peerID)", type: .handshakes)

        return (extensionData, infoHash, peerID)
    }

    private static func writeOutgoingHandshake(for infoHash: InfoHash, with peerID: PeerID, on socket: AsyncSocketWrapper, uuid: UUID) async throws {
        var data = Data([UInt8(19)])
        data.append(Self.BITTORRENT_PROTOCOL_NAME.data(using: .ascii)!)

        data.append(ExtensionData.supportedByMe.bytes)

        data.append(infoHash.bytes)

        data.append(peerID.bytes)

        Logger.shared.log("[\(uuid.uuidString)] Writing outgoing handshake with infoHash \(infoHash)", type: .handshakes)
        try await socket.write(data)
    }

    private actor InternalState {
        // All connections start like this
        var peerChoking = true
        var peerInterested = false
        var usChoking = true
        var usInterested = false

        var peerHaves: Haves

        // This lets us detect the error where a peer sends a bitfield as not the first message
        var hasReceivedFirstMessage = false

        var localHavesCopy: Haves

        var currentPieceData: PieceData? = nil

        init(for torrent: Torrent) async {
            // Assume empty; overwrite if we get a bitfield message
            self.peerHaves = Haves.empty(ofLength: torrent.torrentFile.pieceCount)
            self.localHavesCopy = await torrent.haves
        }

        func peerChoking(_ choking: Bool) {
            self.peerChoking = choking
        }

        func peerInterested(_ interested: Bool) {
            self.peerInterested = interested
        }

        func peerGotPiece(withIndex index: UInt32) {
            self.peerHaves[index] = true
        }

        func updatePeerHaves(from bitfield: Data) {
            self.peerHaves = Haves(fromBitfield: bitfield, length: self.peerHaves.length)
        }
        func peerHasAll() {
            self.peerHaves = Haves.full(ofLength: self.peerHaves.length)
        }
        func peerHasNone() {
            self.peerHaves = Haves.empty(ofLength: self.peerHaves.length)
        }

        func hasReceivedFirstMessageWhileSilentlyUpdating() -> Bool {
            let val = hasReceivedFirstMessage
            hasReceivedFirstMessage = true
            return val
        }

        func receivedChunk(_ data: Data, at offset: UInt32, in index: UInt32) -> Data? {
            self.currentPieceData?.receive(data, at: offset, in: index)
            if self.currentPieceData?.isComplete ?? false {
                if let data = self.currentPieceData?.verify() {
                    self.currentPieceData = nil
                    return data
                }
            }
            return nil
        }
    }

    func runP2P() async throws {
        // TODO: implement peer wire protocol
        try await withThrowingTaskGroup { group in

            let state = await InternalState(for: torrent)

            Logger.shared.log("[\(self)] Writing initial bitfield (\(await state.localHavesCopy.percentComplete, stringFormat: "%.2f")% of file) to connection", type: .peerCommunication)
            async let x: Void = socket.write(state.localHavesCopy.makeMessage())
            try await x

            group.addTask {
                while await torrent.isRunning {
                    let messageLengthData = try await socket.read(bytes: 4)
                    let messageLength = UInt32(bigEndian: Data(messageLengthData).to(type: UInt32.self)!)
                    guard messageLength > 0 else {
                        // This message is a keep-alive; ignore it
                        continue
                    }
                    let messageData = try await socket.read(bytes: Int(messageLength))

                    switch messageData[0] {
                    case 0:
                        // choke
                        await state.peerChoking(true)
                        Logger.shared.log("[\(self)] Peer is now choking us", type: .peerCommunication)
                    case 1:
                        // unchoke
                        await state.peerChoking(false)
                        Logger.shared.log("[\(self)] Peer is no longer choking us", type: .peerCommunication)
                    case 2:
                        // interested
                        await state.peerInterested(true)
                        Logger.shared.log("[\(self)] Peer is now interested in us", type: .peerCommunication)
                    case 3:
                        // not interested
                        await state.peerInterested(false)
                        Logger.shared.log("[\(self)] Peer is no longer interested in us", type: .peerCommunication)
                    case 4:
                        // have
                        let index = UInt32(bigEndian: Data(messageData[1...]).to(type: UInt32.self)!)
                        await state.peerGotPiece(withIndex: index)
                        Logger.shared.log("[\(self)] Peer now has piece \(index)", type: .peerCommunication)
                        // TODO: perhaps kick off another request
                    case 5:
                        // bitfield
                        if await state.hasReceivedFirstMessageWhileSilentlyUpdating() {
                            // The original BitTorrent spec (BEP0003) just says "'bitfield' is only ever sent as the first message."
                            // It doesn't clarify what clients should do if this is violated, but based on other BEPs I believe that
                            //   clients are supposed to close the connection.
                            Logger.shared.warn("[\(self)] Peer sent bitfield after already sending messages", type: .peerCommunication)
                            throw TorrentError.bitfieldAfterStart
                        }
                        let bitfield = Data(messageData[1...])
                        await state.updatePeerHaves(from: bitfield)
                        Logger.shared.log("[\(self)] Peer sent bitfield (has \(await state.localHavesCopy.percentComplete, stringFormat: "%.2f")% of the file)", type: .peerCommunication)
                    case 6:
                        // request
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("[\(self)] Peer requested \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
                        let req = PieceRequest(index: index, offset: begin, length: length)
                        // TODO: build request and add to set
                    case 7:
                        // piece
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let piece = Data(messageData[9...])
                        Logger.shared.log("[\(self)] Peer sent piece (chunk?) at offset \(begin) of piece \(index)", type: .peerCommunication)
                        if let data = await state.receivedChunk(piece, at: begin, in: index) {
                            try await torrent.fileIO.write(data, inPiece: UInt64(index), beginningAt: UInt64(begin))
                        }
                    case 8:
                        // cancel
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("[\(self)] Peer canceled previous request for \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
                        let req = PieceRequest(index: index, offset: begin, length: length)
                        // TODO: build request and remove from set
                    // BEP0005 (DHT PROTOCOL)
                    case 9:
                        // port
                        guard ExtensionData.supportedByMe.contains(.dht) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the DHT protocol (BEP 5), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                    // END BEP0005 (DHT PROTOCOL)
                    // BEP0006 FAST EXTENSION
                    case 0x0D:
                        // suggest piece
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }
                    case 0x0E:
                        // have all
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        if await state.hasReceivedFirstMessageWhileSilentlyUpdating() {
                            Logger.shared.warn("[\(self)] Peer sent haveAll after already sending messages", type: .peerCommunication)
                            throw TorrentError.bitfieldAfterStart
                        }
                        await state.peerHasAll()
                    case 0x0F:
                        // have none
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        if await state.hasReceivedFirstMessageWhileSilentlyUpdating() {
                            Logger.shared.warn("[\(self)] Peer sent haveNone after already sending messages", type: .peerCommunication)
                            throw TorrentError.bitfieldAfterStart
                        }
                        await state.peerHasNone()
                    case 0x10:
                        // reject request
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }
                    case 0x11:
                        // allowed fast
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }
                    // END BEP0006 FAST EXTENSION
                    default:
                        Logger.shared.warn("[\(self)] Unknown message type", type: .peerCommunication)
                        throw TorrentError.unknownP2PMessage
                        // unknown message type
                    }
                }
            }
            group.addTask {
                while await torrent.isRunning {
                    if let cpd = await state.currentPieceData {
                        try await socket.write(cpd.nextFiveRequests().map { $0.makeMessage() }.reduce(Data(), +))
                        // let requests = cpd.nextFiveRequests()
                        // for req in requests {
                        //     try await socket.write(req.makeMessage())
                        // }
                    } else {
                        // currentPieceData == nil => most recent piece was completed
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            }
            try await group.next()
        }
    }

    func close() throws {
        Task {
            await torrent.remove(connection: self)
        }
        try socket.close()
    }
}
