import Foundation
import FlyingSocks
import BencodeKit

let BIND_ADDRESS = "0.0.0.0"
let BIND_PORT: UInt16 = 12345

// https://stackoverflow.com/a/40089462
extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let hexDigits = options.contains(.upperCase) ? "0123456789ABCDEF" : "0123456789abcdef"
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            let utf8Digits = Array(hexDigits.utf8)
            return String(unsafeUninitializedCapacity: 2 * self.count) { (ptr) -> Int in
                var p = ptr.baseAddress!
                for byte in self {
                    p[0] = utf8Digits[Int(byte / 16)]
                    p[1] = utf8Digits[Int(byte % 16)]
                    p += 2
                }
                return 2 * self.count
            }
        } else {
            let utf16Digits = Array(hexDigits.utf16)
            var chars: [unichar] = []
            chars.reserveCapacity(2 * self.count)
            for byte in self {
                chars.append(utf16Digits[Int(byte / 16)])
                chars.append(utf16Digits[Int(byte % 16)])
            }
            return String(utf16CodeUnits: chars, count: chars.count)
        }
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
}

actor Torrent {
    private var sockets: [AsyncSocket] = []
    private var running = false
    private var task: Task<Void, Error>? = nil

    func accept(connection: AsyncSocket) {
        print("[torrent] got connection")
        sockets.append(connection)
        if sockets.count == 1 {
            self.running = true
            self.task = Task {
                while running {
                    for socket in self.sockets {
                        try await socket.write("\(sockets.count) connections\n".data(using: .utf8)!)
                    }
                    try await Task.sleep(nanoseconds: 1000000000)
                }
            }
        }
    }
}

enum TorrentError: Error {
    case nonASCIIProtocol(Data)
    case unknownProtocol(String)
    case unknownInfoHash(InfoHash)
}

actor TorrentClient {
    private var torrents: [InfoHash: Torrent] = [:]

    func accept(connection: AsyncSocket) async throws {
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

        let extensionData = try await connection.read(bytes: 8)
        print("Extension data: \(extensionData)")

        let infoHashRaw = try await connection.read(bytes: 20)
        print("Info hash (raw): \(infoHashRaw)")
        let infoHash = InfoHash.v1(Data(infoHashRaw))
        print("Info hash: \(infoHash)")

        guard let torrent = self.torrents[infoHash] else {
            throw TorrentError.unknownInfoHash(infoHash)
        }

        let peerIDRaw = try await connection.read(bytes: 20)
        
        // TODO: send our handshake back
        try await connection.write("Pretend this is a real BitTorrent handshake\n".data(using: .ascii)!)

        await torrent.accept(connection: connection)
    }

    func start(torrent: InfoHash) {
        torrents[torrent] = Torrent()
    }
}

let client = TorrentClient()

print("[setup] setting up socket...")
let serverTask = Task {
    print("[setup/socket] making pool")
    let pool = SocketPool.make()
    print("[setup/socket] preparing pool")
    try await pool.prepare()
    print("[setup/socket] creating socket")
    let _socket = try Socket(domain: AF_INET, type: .stream)
    print("[setup/socket] binding to \(BIND_ADDRESS):\(BIND_PORT)")
    do { try _socket.bind(to: .inet(ip4: BIND_ADDRESS, port: BIND_PORT)) } catch { print(error, "Unable to bind to address!"); exit(0) }
    print("[setup/socket] listening")
    do { try _socket.listen() } catch { print(error, "Unable to listen"); exit(0) }
    print("[setup/socket] converting to async socket")
    let serverSocket = try AsyncSocket(socket: _socket, pool: pool)

    print("[setup/controlsocket] removing whatever was at path")
    try? FileManager.default.removeItem(atPath: "/tmp/testbed.sock")
    print("[setup/controlsocket] creating socket")
    let __s = try Socket(domain: AF_UNIX, type: .stream)
    print("[setup/controlsocket] binding to path")
    try __s.bind(to: .unix(path: "/tmp/testbed.sock"))
    print("[setup/controlsocket] listening")
    try __s.listen()
    print("[setup/controlsocket] converting to async socket")
    let __ss = try AsyncSocket(socket: __s, pool: pool)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            print("[setup/socket] running pool")
            try await pool.run()
        }
        group.addTask {
            print("[setup/socket] awaiting connections")
            for try await conn in serverSocket.sockets {
                let u = UUID()
                print("[socket/\(u)] got connection")
                do {
                    try await client.accept(connection: conn)
                } catch {
                    print(error)
                    try conn.close()
                }
            }
        }
        group.addTask {
            for try await conn in __ss.sockets {
                print("got control connection")
                switch try await conn.read(bytes: 1)[0] {
                case UInt8(ascii: "S"): //start
                    let _infoHash = try await conn.read(bytes: 20)
                    let infoHash = InfoHash.v1(Data(_infoHash))
                    await client.start(torrent: infoHash)
                    try await conn.write("Starting torrent \(infoHash)".data(using: .utf8)!)
                    print("Starting torrent \(infoHash)")
                default:
                    try await conn.write("Unknown control command".data(using: .utf8)!)
                    print("Unknown control command")
                }
                try conn.close()
            }
        }
        try await group.next()
    }
}

print("dispatchMain")
dispatchMain()
