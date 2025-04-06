import Foundation

enum TorrentError: Error {
    case nonASCIIProtocol(Data)
    case unknownProtocol(String)
    case wrongInfoHash(InfoHash)
    case invalidAnnounceURL(String)
    case pausedTorrent(InfoHash)
    case unsupportedExtension(BEP: Int?)
    case bitfieldAfterStart
}
