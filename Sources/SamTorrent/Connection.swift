import Foundation
import FlyingSocks

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
