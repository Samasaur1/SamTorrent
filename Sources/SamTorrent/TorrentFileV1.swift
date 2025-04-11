import BencodeKit
import Foundation

// See: https://www.bittorrent.org/beps/bep_0003.html
public struct TorrentFileV1: Codable, Sendable {
    struct InfoDictionary: Codable {
        struct MultipleFileInfo: Codable {
            let length: Int
            let path: [String]
        }

        let name: String
        let pieceLength: Int
        let pieces: Data

        let length: Int?
        let files: [MultipleFileInfo]?

        enum CodingKeys: String, CodingKey {
            case name
            case pieceLength = "piece length"
            case pieces
            case length
            case files
            case md5sum, sha1, sha256
        }

        let md5sum: Data?
        let sha1: Data?
        let sha256: Data?
    }

    let announce: String
    let info: InfoDictionary


    var length: Int {
        info.length ?? info.files!.map { $0.length }.reduce(0, +)
    }
    var pieceCount: Int {
        Int( (Double(length)/Double(info.pieceLength)) .rounded(.up) )
    }
}

public struct TorrentFile: Sendable {
    struct File: Sendable {
        let length: Int
        let pathFromRoot: [String]
    }

    let length: Int
    let pieces: [Data]
    let pieceCount: Int
    let pieceLength: Int
    let name: String
    let announce: String

    let files: [File]

    init(from torrentFile: TorrentFileV1) {
        self.length = torrentFile.info.length ?? torrentFile.info.files!.map { $0.length }.reduce(0, +)
        guard torrentFile.info.pieces.count.isMultiple(of: 20) else {
            fatalError()
        }
        self.pieces = torrentFile.info.pieces.chunks(ofSize: 20)
        self.pieceCount = self.pieces.count
        self.pieceLength = torrentFile.info.pieceLength
        self.name = torrentFile.info.name
        self.announce = torrentFile.announce

        if let l = torrentFile.info.length {
            self.files = [File(length: l, pathFromRoot: [])]
        } else {
            self.files = torrentFile.info.files!.map { File(length: $0.length, pathFromRoot: $0.path) }
        }

        guard self.pieces.count == Int( (Double(self.length)/Double(self.pieceLength)) .rounded(.up) ) else {
            fatalError()
        }
    }
}
