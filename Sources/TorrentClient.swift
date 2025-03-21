import Foundation
import FlyingSocks

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
