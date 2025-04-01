import BencodeKit
import Foundation

// See: https://www.bittorrent.org/beps/bep_0003.html
struct TorrentFileV1: Codable {
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
        }
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
