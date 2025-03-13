import Foundation
import FlyingSocks

let BIND_ADDRESS = "0.0.0.0"
let BIND_PORT: UInt16 = 12345

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

var torrents: [Int: Torrent] = [:]
torrents[0] = Torrent()

print("[setup] setting up socket...")
let serverTask = Task {
    print("[setup/socket] making pool")
    let pool = SocketPool.make()
    print("[setup/socket] preparing pool")
    try await pool.prepare()
    print("[setup/socket] creating socket")
    let _socket = try Socket(domain: AF_INET, type: .stream)
    print("[setup/socket] binding to \(BIND_ADDRESS):\(BIND_PORT)")
    try _socket.bind(to: .inet(ip4: BIND_ADDRESS, port: BIND_PORT))
    try _socket.listen()
    let serverSocket = try AsyncSocket(socket: _socket, pool: pool)
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
                await torrents[0]?.accept(connection: conn)
            }
        }
        try await group.next()
    }
}

// let ioTask = Task {
//     while let x = readLine() {
//         print("read \(x)")
//     }
// }

print("dispatchMain")
dispatchMain()
