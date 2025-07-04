import Foundation
import SamTorrent
import BencodeKit
import AsyncAlgorithms

let client = TorrentClient()

#if !canImport(Darwin)
struct StandardInputLineIterator: AsyncIteratorProtocol {
    typealias Element = String

    mutating func next(isolation actor: isolated (any Actor)?) async -> String? {
        return readLine()
    }
}
#endif

let ioTask = Task {
    if #available(macOS 12.0, *) {
        #if canImport(Darwin)
        var it = FileHandle.standardInput.bytes.lines.makeAsyncIterator()
        #else
        var it = StandardInputLineIterator()
        #endif
        print("made asynciterator")
        while true {
            guard let line = try? await it.next() else { break }
            print("got line")
            var lit = line.split(separator: " ").makeIterator()
            switch lit.next() {
            case "torrentfile":
                let path = lit.joined(separator: " ")
                print("Loading torrent from metainfo file at '\(path)'")
                guard let url = URL(string: path) else {
                    print("cannot construct URL from path")
                    continue
                }
                print("converted path to URL \(url)")
                print("file at path \(url.path) exists: \(FileManager.default.fileExists(atPath: url.path))")
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    print("cannot load torrent file")
                    continue
                }
                guard let tf = try? BencodeDecoder().decode(TorrentFileV1.self, from: data) else {
                    print("cannot decode torrent file")
                    continue
                }
                try await client.addTorrent(from: tf)
            // case "infohash":
            //     guard let hash = lit.next() else { continue }
            //     let data = hash.data(using: .utf8)!
            //     guard data.count == 20 else { print("info hash wrong length (was \(data.count), must be 20)"); continue }
            //     let infoHash = InfoHash.v1(data)
            //     await client.__addTorrentBy(infoHash: infoHash)
            //     print("started torrent with info hash \(infoHash)")
            case "list":
                print("client has torrents with info hashes:")
                for (ih, t) in await client.torrents {
                    let percentComplete = await t.percentComplete
                    if await t.isRunning {
                        let count = await t.connections.count
                        print("- \(ih) (\(percentComplete), running, \(count) peer(s))")
                    } else {
                        print("- \(ih) (\(percentComplete), not running)")
                    }
                }
            case "resume":
                guard let hash = lit.next() else { continue }
                let data = hash.data(using: .utf8)!
                guard data.count == 20 else { print("info hash wrong length (was \(data.count), must be 20)"); continue }
                let infoHash = InfoHash.v1(data)
                await client.torrents[infoHash]?.resume()
                print("resuming torrent with info hash \(infoHash)")
            case "pause":
                guard let hash = lit.next() else { continue }
                let data = hash.data(using: .utf8)!
                guard data.count == 20 else { print("info hash wrong length (was \(data.count), must be 20)"); continue }
                let infoHash = InfoHash.v1(data)
                await client.torrents[infoHash]?.pause()
                print("pausing torrent with info hash \(infoHash)")
            case "resumeall":
                await withTaskGroup(of: Void.self) { group in
                    for (infoHash, torrent) in await client.torrents {
                        group.addTask {
                            await torrent.resume()
                            print("\(infoHash) resumed")
                        }
                    }
                }
            case "pauseall":
                await withTaskGroup(of: Void.self) { group in
                    for (infoHash, torrent) in await client.torrents {
                        group.addTask {
                            await torrent.pause()
                            print("\(infoHash) paused")
                        }
                    }
                }
            case "resumeinteractive":
                async let pausedTorrents = Array(client.torrents.async.filter { await !$0.value.isRunning }).enumerated()
                print("Choose a torrent to resume:")
                for (idx, (ih, t)) in await pausedTorrents {
                    print("(\(idx)): \(ih)")
                }
                let choice = Int(readLine()!)
                guard let torrent = await pausedTorrents.first(where: { $0.offset == choice }) else {
                    print("Invalid selection")
                    continue
                }
                await torrent.element.value.resume()
                print("\(torrent.element.key) resumed")
            case "pauseinteractive":
                async let runningTorrents = Array(client.torrents.async.filter { await $0.value.isRunning }).enumerated()
                print("Choose a torrent to pause:")
                for (idx, (ih, t)) in await runningTorrents {
                    print("(\(idx)): \(ih)")
                }
                let choice = Int(readLine()!)
                guard let torrent = await runningTorrents.first(where: { $0.offset == choice }) else {
                    print("Invalid selection")
                    continue
                }
                await torrent.element.value.pause()
                print("\(torrent.element.key) paused")
            case "connectto":
                await client.torrents.first!.value.makeConnection(to: .random(), at: try! .inet(ip4: "127.0.0.1", port: 6881))
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
