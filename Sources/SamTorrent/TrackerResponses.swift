import Foundation

struct FailedTrackerResponse: Codable {
    let failureReason: String

    enum CodingKeys: String, CodingKey {
        case failureReason = "failure reason"
    }
}
struct TrackerResponse: Codable {
    let interval: Int
    let trackerID: String?
    let complete: Int
    let incomplete: Int
    let peers: [PeerInfo] //TODO: support compact binary model as well. custom decode function?

    enum CodingKeys: String, CodingKey {
        case interval, complete, incomplete, peers
        case trackerID = "tracker id"
    }
}
struct PeerInfo: Codable {
    let peerID: Data
    let ip: String
    let port: UInt16

    enum CodingKeys: String, CodingKey {
        case ip, port
        case peerID = "peer id"
    }
}
