import Foundation
import FlyingSocks
import BencodeKit

let BIND_ADDRESS = "0.0.0.0"
let BIND_PORT: UInt16 = 12345

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
    private var trackerTask: Task<Void, Error>? = nil

    private enum Event: String {
        case start = "started"
        case stop = "stopped"
    }

    // private func request(to event: Event? = nil) -> URLRequest {
    //     var s = "trackerURL"
    //     var request = URLRequest(url: URL(string: "")!)
    // }

    var running = false {
        didSet {
            if running != oldValue {
                // self.trackerTask = Task {
                //     try await 
                // }
                self.task = Task {
                    while running {
                        // try await withTaskGroup(of: Void.self) { group in
                        //     group.addTask {
                        //         var request = URLRequest(url: URL(string: "")!)
                        //         request.httpMethod = "GET"
                        //         let (data, response) = try! await URLSession.shared.data(for: request)
                        //     }
                        // }
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
