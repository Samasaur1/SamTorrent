public protocol TorrentClientViz {
    associatedtype T: TorrentViz

    var torrents: [InfoHash: T] { get async }
    var peerID: PeerID { get }
}

public protocol TorrentViz {
    var isRunning: Bool { get async }
    // var connections: [PeerConnection] { get }
}

extension TorrentClient: TorrentClientViz {}
extension Torrent: TorrentViz {}
