import FlyingSocks
import Foundation

struct AsyncSocketWrapper {
    private let socket: AsyncSocket

    init(wrapping: AsyncSocket) {
        self.socket = wrapping
    }

    static func connected(to address: SocketAddress, pool: AsyncSocketPool) async throws -> AsyncSocketWrapper {
        return try await AsyncSocketWrapper(wrapping: AsyncSocket.connected(to: address, pool: pool))
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
