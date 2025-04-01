import Foundation
import FlyingSocks
import BencodeKit

struct ExtensionData: OptionSet {
    let rawValue: UInt64

    // static let fast: ExtensionData = ExtensionData(rawValue: 1 << 0)

    static let supportedByMe: ExtensionData = []
}
extension ExtensionData {
    init(from bytes: [UInt8]) {
        rawValue = unsafeBitCast(bytes, to: UInt64.self)
        // TODO: fix this
    }

    var bytes: Data {
        Data()
        // TODO: fix this too
    }
}

enum InfoHash: Hashable, CustomStringConvertible {
    case v1(Data)

    var description: String {
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
}


struct PeerID {
    var bytes: Data {
        Data()
    }
}

public actor TorrentClient {
    let peerID: PeerID
    var torrents: [InfoHash: Torrent]

    init() {
        self.peerID = PeerID()
        self.torrents = [:]
    }

    public func launch() async throws {
        print("making pool")
        let pool = SocketPool.make()
        print("preparing pool")
        try await pool.prepare()
        print("creating socket")
        let _socket = try Socket(domain: AF_INET, type: .stream)
        print("disabling SIGPIPE")
        try _socket.setValue(true, for: .noSIGPIPE)
        print("binding to address")
        do { try _socket.bind(to: .inet(ip4: BIND_ADDRESS, port: BIND_PORT)) } catch { print(error, "Unable to bind to address!"); exit(0) }
        print("listening")
        do { try _socket.listen() } catch { print(error, "Unable to listen"); exit(0) }
        print("creating async socket")
        let serverSocket = try AsyncSocket(socket: _socket, pool: pool)

        print("setup complete")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pool.run()
            }
            group.addTask {
                try await withThrowingDiscardingTaskGroup { group in
                    for try await conn in serverSocket.sockets {
                        group.addTask {
                            defer { try? conn.close() }
                            await self.accept(connection: conn)
                        }
                    }
                }
                throw SocketError.disconnected
            }
            try await group.next()
        }
    }

    private func accept(connection: AsyncSocket) async {
        let (_, infoHash, peerID) = try! await readIncomingHandshake(on: connection)

        guard let torrent = self.torrents[infoHash] else {
            print("no torrent with info hash")
            return
        }

        guard await torrent.isRunning else {
            print("torrent is not running")
            return
        }

        try? await writeOutgoingHandshake(for: infoHash, with: self.peerID, on: connection)

        try? await self.postHandshake(for: infoHash, on: connection)
    }

    private func readIncomingHandshake(on connection: AsyncSocket) async throws -> (ExtensionData, InfoHash, PeerID) {
        let protocolLength = try await Int(connection.read(bytes: 1)[0])
        print("\(protocolLength) byte protocol name")
        let protocolBytes = try await connection.read(bytes: protocolLength)
        guard let protocolName = String(bytes: protocolBytes, encoding: .ascii) else {
            throw TorrentError.nonASCIIProtocol(Data(protocolBytes))
        }
        print("Protocol: \(protocolName)")
        guard protocolName == "BitTorrent Protocol" else {
            throw TorrentError.unknownProtocol(protocolName)
        }

        let extensionDataRaw = try await connection.read(bytes: 8)
        print("Extension data (raw): \(extensionDataRaw)")
        let extensionData = ExtensionData(from: extensionDataRaw)
        print("Extension data: \(extensionData)")

        let infoHashRaw = try await connection.read(bytes: 20)
        print("Info hash (raw): \(infoHashRaw)")
        let infoHash = InfoHash.v1(Data(infoHashRaw))
        print("Info hash: \(infoHash)")

        let peerIDRaw = try await connection.read(bytes: 20)

        return (extensionData, infoHash, PeerID())
    }

    private func writeOutgoingHandshake(for infoHash: InfoHash, with peerID: PeerID, on connection: AsyncSocket) async throws {
        var data = Data([UInt8(19)])
        data.append("BitTorrent Protocol".data(using: .ascii)!)

        data.append(ExtensionData.supportedByMe.bytes)

        data.append(infoHash.bytes)

        data.append(peerID.bytes)

        try await connection.write(data)
    }

    private func postHandshake(for infoHash: InfoHash, on connection: AsyncSocket) async throws {
        // TODO: implement peer wire protocol
        while true {
            try await Task.sleep(for: .seconds(1))
            try await connection.write("Hello\n".data(using: .ascii)!)
        }
    }
}

extension TorrentClient {
    func __addTorrentBy(infoHash: InfoHash) {
        self.torrents[infoHash] = Torrent()
    }
}

let BIND_ADDRESS = "0.0.0.0"
let BIND_PORT: UInt16 = 12345

public actor Torrent {
    public var isRunning: Bool = false

    private enum Event: String {
        case start = "started"
        case stop = "stopped"
    }

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
    case unknownInfoHash(InfoHash)
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
            case "infohash":
                guard let hash = lit.next() else { continue }
                let infoHash = InfoHash.v1(hash.data(using: .utf8)!)
                await client.__addTorrentBy(infoHash: infoHash)
                print("started torrent with info hash \(infoHash)")
            case "list":
                print("client has torrents with info hashes:")
                for t in await client.torrents.keys {
                    print("- \(t)")
                }
            case "resume":
                guard let hash = lit.next() else { continue }
                let infoHash = InfoHash.v1(hash.data(using: .utf8)!)
                await client.torrents[infoHash]?.resume()
                print("resuming torrent with info hash \(infoHash)")
            case "pause":
                guard let hash = lit.next() else { continue }
                let infoHash = InfoHash.v1(hash.data(using: .utf8)!)
                await client.torrents[infoHash]?.pause()
                print("pausing torrent with info hash \(infoHash)")
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

print("dM()")
dispatchMain()
