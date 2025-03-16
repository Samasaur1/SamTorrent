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

// https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
extension Sequence {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }
    //
    // func concurrentMap<T: Sendable>(
    //     _ transform: @escaping (Element) async throws -> T
    // ) async rethrows -> [T] {
    //     let tasks = map { element in
    //         Task {
    //             try await transform(element)
    //         }
    //     }
    //
    //     return try await tasks.asyncMap { task in
    //         try await task.value
    //     }
    // }
}

actor AsyncSocketWrapper {
    public let socket: AsyncSocket
    public private(set) var disconnected: Bool = false

    init(socket: AsyncSocket) {
        self.socket = socket
    }

    public func read(bytes: Int) async throws -> Data {
        do {
            return try await Data(socket.read(bytes: bytes))
        } catch let error as SocketError {
            print("wrapper: read error: \(error)")
            switch error {
            case .disconnected:
                self.disconnected = true
            default: break
            }
            throw error
        }
    }

    public func write(_ data: Data) async throws {
        do {
            try await socket.write(data)
        } catch let error as SocketError {
            print("wrapper: write error: \(error)")
            switch error {
            case .disconnected:
                self.disconnected = true
            case let .failed(type: type, errno: errno, message: message):
                if errno == 32 { self.disconnected = true }
            default: break
            }
            throw error
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
    private var sockets: [AsyncSocketWrapper] = []
    private var task: Task<Void, Error>? = nil

    var running = false {
        didSet {
            if running != oldValue {
                self.task = Task {
                    while running {
                        print("removing sockets")
                        await self.removeDisconnectedSockets()
                        let count = sockets.count
                        print("\(count) sockets remaining")
                        await withTaskGroup(of: Void.self) { group in
                            for socket in self.sockets {
                                group.addTask {
                                    print("about to write to socket (disconnected: \(await socket.disconnected))")
                                    do {
                                        try await socket.write("\(count) connections\n".data(using: .utf8)!)
                                        print("wrote to socket")
                                    } catch {
                                        print("failed to write")
                                    }
                                    print("disconnected: \(await socket.disconnected)")
                                }
                            }
                        }
                        print("Task is canceled: \(Task.isCancelled)")
                        print("sleeping")
                        try await Task.sleep(nanoseconds: 1000000000)
                        print("running: \(running)")
                    }
                    // while running {
                    //     let count = sockets.count
                    //     let toRemove = await withTaskGroup(of: [Int].self, returning: [Int].self) { group in
                    //         for i in 0..<count {
                    //             let socket = self.sockets[i]
                    //             group.addTask {
                    //                 do {
                    //                     try await socket.write("\(count) connections\n".data(using: .utf8)!)
                    //                     return []
                    //                 } catch {
                    //                     return [i]
                    //                 }
                    //             }
                    //         }
                    //         return group.reduce(into: [], { $0.append($1) }
                    //     }
                    // }
                    // while running {
                    //     let count = sockets.count
                    //     let socketsCopy = sockets
                    //     var toRemove = [Int]()
                    //     await withTaskGroup(of: Void.self) { group in
                    //         // for socket in self.sockets {
                    //         //     group.addTask {
                    //         //         do {
                    //         //             try await socket.write("\(count) connections\n".data(using: .utf8)!)
                    //         //         } catch {
                    //         //             socket.socket.file.rawValue.
                    //         //         }
                    //         //     }
                    //         // }
                    //         for i in 0..<count {
                    //             let socket = socketsCopy[i]
                    //             group.addTask {
                    //                 do {
                    //                     try await socket.write("\(count) connections\n".data(using: .utf8)!)
                    //                 } catch {
                    //                     // toRemove.append(i)
                    //                 }
                    //             }
                    //         }
                    //     }
                    //     for index in toRemove.sorted().reversed() {
                    //         self.sockets.remove(at: index)
                    //     }
                    //     try await Task.sleep(nanoseconds: 1000000000)
                    // }
                }
            }
        }
    }

    func removeDisconnectedSockets() async {
        // self.sockets.removeAll { socket in socket.disconnected }
        let disconnected = await self.sockets.asyncMap { socket in await socket.disconnected }
        if #available(macOS 15.0, *) {
            let indices = disconnected.indices(of: true)
            print("indices to remove: \(indices)")
            self.sockets.removeSubranges(indices)
        } else {
            // Fallback on earlier versions
            for (idx, disconnected) in disconnected.enumerated().reversed() {
                if disconnected { self.sockets.remove(at: idx) }
            }
        }
    }

    func accept(connection: AsyncSocket) {
        print("[torrent] got connection")
        sockets.append(AsyncSocketWrapper(socket: connection))
    }

    func pause() {
        self.running = false
    }

    func resume() {
        self.running = true
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

    func pause(torrent: InfoHash) async {
        await torrents[torrent]?.pause()
    }

    func resume(torrent: InfoHash) async {
        await torrents[torrent]?.resume()
    }

    func pauseAll() async {
        await withTaskGroup(of: Void.self) { group in
            for (_, torrent) in self.torrents {
                group.addTask {
                    await torrent.pause()
                }
            }
        }
    }

    func resumeAll() async {
        await withTaskGroup(of: Void.self) { group in
            for (_, torrent) in self.torrents {
                group.addTask {
                    await torrent.resume()
                }
            }
        }
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
                case UInt8(ascii: "T"): //torrent
                    let _infoHash = try await conn.read(bytes: 20)
                    let infoHash = InfoHash.v1(Data(_infoHash))
                    await client.start(torrent: infoHash)
                    try await conn.write("Starting torrent \(infoHash)".data(using: .utf8)!)
                    print("Starting torrent \(infoHash)")
                case UInt8(ascii: "G"): //go
                    await client.resumeAll()
                    try await conn.write("Resuming all torrents".data(using: .utf8)!)
                    print("Resuming all torrents")
                case UInt8(ascii: "S"): //stop
                    await client.pauseAll()
                    try await conn.write("Pausing all torrents".data(using: .utf8)!)
                    print("Pausing all torrents")
                case UInt8(ascii: "P"): //pause
                    let _infoHash = try await conn.read(bytes: 20)
                    let infoHash = InfoHash.v1(Data(_infoHash))
                    await client.pause(torrent: infoHash)
                    try await conn.write("Pausing torrent \(infoHash)".data(using: .utf8)!)
                    print("Pausing torrent \(infoHash)")
                case UInt8(ascii: "R"): //resume
                    let _infoHash = try await conn.read(bytes: 20)
                    let infoHash = InfoHash.v1(Data(_infoHash))
                    await client.resume(torrent: infoHash)
                    try await conn.write("Resuming torrent \(infoHash)".data(using: .utf8)!)
                    print("Resuming torrent \(infoHash)")
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

let ioTask = Task {
    if #available(macOS 12.0, *) {
        for try await line in FileHandle.standardInput.bytes.lines {
            print("Got line: \(line)")
        }
    }
}

print("dispatchMain")
dispatchMain()
