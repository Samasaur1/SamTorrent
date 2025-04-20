import Foundation
import FlyingSocks
import BencodeKit

struct ExtensionProtocolHandshake: Codable {
    struct SupportedExtensions: Codable {
        var peerExchange: UInt8?
        // other extension protocol extensions

        // other things in the handshake

        enum CodingKeys: String, CodingKey {
            case peerExchange = "ut_pex"
        }

        static func makeForMe() -> Self {
            return Self(
                peerExchange: 0
            )
        }
    }

    let supportedExtensions: SupportedExtensions

    // BEP0010 Extension Protocol
    let listeningPort: UInt16?
    let clientVersion: String?
    let yourIP: String?
    let ipv6: Data?
    let ipv4: Data?
    let outstandingRequests: Int?

    // BEP0009 Extension for Peers to Send Metadata Files
    let metadataSize: Int?

    enum CodingKeys: String, CodingKey {
        case supportedExtensions = "m"
        case listeningPort = "p"
        case clientVersion = "v"
        case yourIP = "yourip"
        case ipv6, ipv4
        case outstandingRequests = "reqq"

        case metadataSize = "metadata_size"
    }

    static func makeForMe() -> Self {
        return Self(
            supportedExtensions: .makeForMe(),
            listeningPort: nil,
            clientVersion: "SamTorrent 0.1.0",
            yourIP: nil,
            ipv6: nil,
            ipv4: nil,
            outstandingRequests: nil,
            metadataSize: nil,
        )
    }
}

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

    static func outgoing(to peerID: PeerID?, at address: SocketAddress, for torrent: Torrent, asPartOf client: TorrentClient) async throws -> PeerConnection {
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
            } catch let error as TimeoutError {
                Logger.shared.warn("[\(uuid.uuidString)] Timed out while attempting to connect to \(addrString)", type: .outgoingConnections)
                throw error
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
        } catch let error as TimeoutError {
            Logger.shared.warn("[\(uuid.uuidString)] Connection timed out", type: .outgoingConnections)
            throw error
        } catch {
            Logger.shared.warn("[\(uuid.uuidString)] Connection closed with error: \(error)", type: .outgoingConnections)
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
        var localHavesCopy: Haves

        // This lets us detect the error where a peer sends a bitfield as not the first message
        var hasReceivedFirstMessage = false

        var currentPieceData: PieceData? = nil

        var peerRequests: Set<PieceRequest> = []
        var ourRequests: Set<PieceRequest> = []

        private var connection: PeerConnection

        init(for connection: PeerConnection) async {
            // Assume empty; overwrite if we get a bitfield message
            self.peerHaves = Haves.empty(ofLength: connection.torrent.torrentFile.pieceCount)
            self.localHavesCopy = await connection.torrent.haves
            self.connection = connection
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

        func receivedChunk(_ data: Data, at offset: UInt32, in index: UInt32) async {
            self.currentPieceData?.receive(data, at: offset, in: index)
            self.ourRequests.remove(PieceRequest(index: index, offset: offset, length: UInt32(data.count)))
            await self.connection.torrent.reportDownloaded(data.count)
        }

        func got(_ request: PieceRequest) {
            self.peerRequests.insert(request)
        }
        func canceled(_ request: PieceRequest) {
            self.peerRequests.remove(request)
        }

        func update() async throws -> Data {
            var data = Data()
            var newInterest = self.usInterested
            let pieceDataWasAlreadyNil = self.currentPieceData == nil

            let upToDate = await connection.torrent.haves
            // We calculate this so that we can announce to the peer that we have these pieces
            let newPieces = upToDate.newPieces(fromOld: self.localHavesCopy)
            self.localHavesCopy = upToDate

            for newPiece in newPieces {
                data.append(makeHaveMessage(for: newPiece))
                Logger.shared.warn("[\(connection)] Informing peer that we have piece \(newPiece)", type: .peerCommunication)
            }

            if let currentPieceData {
                if localHavesCopy[currentPieceData.idx] {
                    // Another connection has grabbed this piece
                    self.currentPieceData = nil
                    Logger.shared.warn("[\(connection)] Another connection has finished piece \(currentPieceData.idx), which we were working on", type: .peerCommunication)
                } else if currentPieceData.isComplete {
                    // We have completed this piece
                    if let data = currentPieceData.verify() {
                        Logger.shared.log("[\(connection)] Finished piece \(currentPieceData.idx)", type: .peerCommunication)
                        try await connection.torrent.fileIO.write(data, inPiece: UInt64(currentPieceData.idx), beginningAt: 0)
                        await self.connection.torrent.gotPiece(at: currentPieceData.idx)
                        self.currentPieceData = nil
                    } else {
                        Logger.shared.warn("[\(connection)] Peer gave us a piece that didn't match the expected hash", type: .peerCommunication)
                    }
                } else {
                    // Neither we nor another connection have completed this piece
                    // I think this way of queuing requests is not optimal but should work
                    if !peerChoking {
                        // Queue up some requests
                        let requests = currentPieceData.nextFiveRequests()
                        for r in requests {
                            guard !ourRequests.contains(r) else { continue }
                            if ourRequests.count >= 5 { break }
                            ourRequests.insert(r)
                            data.append(r.makeMessage())
                            Logger.shared.log("[\(connection)] Requesting \(r.length) bytes at offset \(r.offset) of piece \(r.index)", type: .peerCommunication)
                        }
                    }
                }
            }

            if currentPieceData == nil {
                // We need to pick a new piece
                let potentialPieces = self.peerHaves.newPieces(fromOld: self.localHavesCopy)
                if potentialPieces.isEmpty {
                    newInterest = false
                    if !pieceDataWasAlreadyNil {
                        Logger.shared.log("[\(connection)] Can't steal from peer because we've completely eclipsed them in research", type: .peerCommunication)
                    }
                } else {
                    newInterest = true
                    let index = potentialPieces.randomElement()!
                    Logger.shared.log("[\(connection)] Now working on piece \(index)", type: .peerCommunication)
                    let size: Int
                    if index == self.connection.torrent.torrentFile.pieceCount - 1 {
                        size = self.connection.torrent.torrentFile.length - (Int(index) * self.connection.torrent.torrentFile.pieceLength)
                    } else {
                        size = self.connection.torrent.torrentFile.pieceLength
                    }
                    self.currentPieceData = PieceData(idx: index, size: UInt32(size), pieceHash: self.connection.torrent.torrentFile.pieces[Int(index)])
                }
            }

            if peerChoking {
                self.ourRequests = []
            }

            // Update choking and interest
            if newInterest != usInterested {
                usInterested = newInterest
                var d = Data(from: UInt32(1).bigEndian)
                d.append(usInterested ? 2 : 3)
                data.append(d)
            }

            // For now we never choke
            if usChoking {
                usChoking = true
                var d = Data(from: UInt32(1).bigEndian)
                d.append(1)
                data.append(d)
            }

            // Share pieces
            for r in peerRequests {
                let chunk = try await connection.torrent.fileIO.read(ofLength: Int(r.length), fromPiece: UInt64(r.index), beginningAt: UInt64(r.offset))
                data.append(makeChunkMessage(for: r, with: chunk))
            }

            return data
        }

        private func makeHaveMessage(for index: UInt32) -> Data {
            var d = Data(from: UInt32(5).bigEndian)
            d.append(4)
            d.append(Data(from: index.bigEndian))
            return d
        }
        private func makeChunkMessage(for request: PieceRequest, with data: Data) -> Data {
            var d = Data(from: UInt32(9 + data.count).bigEndian)
            d.append(7)
            d.append(Data(from: request.index.bigEndian))
            d.append(Data(from: request.offset.bigEndian))

            return d + data
        }
    }

    func runP2P() async throws {
        // TODO: implement peer wire protocol
        try await withThrowingTaskGroup { group in
            let state = await InternalState(for: self)

            if self.supportedExtensions.contains(.extension) && ExtensionData.supportedByMe.contains(.extension) {
                // The extension protocol (BEP0010) says this message
                // "should be sent immediately after the standard bittorrent handshake to any peer that supports this extension protocol."
                // It doesn't clarify how this interacts with the original spec (BEP0003) saying that bitfield messages must be first
                // or with the fast extension (BEP0006) and its have all/have none messages.
                // Anecdotal evidence from running my client seems to imply that the convention is to do the extension protocol handshake first.
                let handshake = ExtensionProtocolHandshake.makeForMe()
                let data = try BencodeEncoder().encode(handshake)
                Logger.shared.log("[\(self)] Writing extension protocol handshake \(handshake)", type: .peerCommunication)
                try await socket.write(data)
            }

            Logger.shared.log("[\(self)] Writing initial bitfield (\(await state.localHavesCopy.percentString) of file) to connection", type: .peerCommunication)
            try await socket.write(state.localHavesCopy.makeMessage())

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
                        Logger.shared.log("[\(self)] Peer sent bitfield (has \(await state.peerHaves.percentString) of the file)", type: .peerCommunication)
                    case 6:
                        // request
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("[\(self)] Peer requested \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
                        let req = PieceRequest(index: index, offset: begin, length: length)
                        await state.got(req)
                    case 7:
                        // piece
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let piece = Data(messageData[9...])
                        Logger.shared.log("[\(self)] Peer sent piece (chunk?) at offset \(begin) of piece \(index)", type: .peerCommunication)
                        await state.receivedChunk(piece, at: begin, in: index)
                    case 8:
                        // cancel
                        let index = UInt32(bigEndian: Data(messageData[1..<5]).to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: Data(messageData[5..<9]).to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: Data(messageData[9...]).to(type: UInt32.self)!)
                        Logger.shared.log("[\(self)] Peer canceled previous request for \(length) bytes at offset \(begin) of piece \(index)", type: .peerCommunication)
                        let req = PieceRequest(index: index, offset: begin, length: length)
                        await state.canceled(req)
                    // BEP0005 (DHT PROTOCOL)
                    case 9:
                        // port
                        guard supportedExtensions.contains(.dht) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                        guard ExtensionData.supportedByMe.contains(.dht) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the DHT protocol (BEP 5), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }

                        // TODO: implement
                    // END BEP0005 (DHT PROTOCOL)
                    // BEP0006 FAST EXTENSION
                    case 0x0D:
                        // suggest piece
                        guard supportedExtensions.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        // TODO: implement
                    case 0x0E:
                        // have all
                        guard supportedExtensions.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
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
                        guard supportedExtensions.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
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
                        guard supportedExtensions.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        // TODO: implement
                    case 0x11:
                        // allowed fast
                        guard supportedExtensions.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                        guard ExtensionData.supportedByMe.contains(.fast) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the fast extension (BEP 6), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 6)
                        }

                        // TODO: implement
                    // END BEP0006 FAST EXTENSION
                    // BEP0010 EXTENSION PROTOCOL
                    case 20:
                        // extended
                        guard supportedExtensions.contains(.extension) else {
                            Logger.shared.warn("[\(self)] Peer sent P2P message it claims not to support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 5)
                        }
                        guard ExtensionData.supportedByMe.contains(.extension) else {
                            Logger.shared.warn("[\(self)] Got P2P message that requires the extension protocol (BEP 10), which we don't support", type: .peerCommunication)
                            throw TorrentError.unsupportedExtension(BEP: 10)
                        }

                        switch messageData[1] {
                        case 0:
                            // handshake
                            let decoder = BencodeDecoder()
                            decoder.unknownKeyDecodingStrategy = .ignore
                            let handshake = try decoder.decode(ExtensionProtocolHandshake.self, from: messageData[2...])
                            Logger.shared.log("[\(self)] Got extension protocol handshake with \(handshake.supportedExtensions)", type: .peerCommunication)
                            if let client = handshake.clientVersion {
                                Logger.shared.log("[\(self)] Peer self-reports client as '\(client)'", type: .peerCommunication)
                            }
                        default:
                            Logger.shared.error("[\(self)] Got extension protocol message that we don't support", type: .peerCommunication)
                            throw TorrentError.unknownP2PMessage
                        }
                    // END BEP0010 EXTENSION PROTOCOL
                    default:
                        Logger.shared.warn("[\(self)] Unknown message type", type: .peerCommunication)
                        throw TorrentError.unknownP2PMessage
                        // unknown message type
                    }
                }
            }
            group.addTask {
                // TODO: serve peer requests
                while await torrent.isRunning {
                    let dataToSend = try await state.update()
                    // This allows the sending to happen during the 1-second sleep
                    async let finishSending: () = socket.write(dataToSend)
                    try await Task.sleep(for: .seconds(1))
                    try await finishSending
                }
                // TODO: this would be so that the other task in the task group cancels when `torrent.isRunning` becomes false
                // group.cancelAll()
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
