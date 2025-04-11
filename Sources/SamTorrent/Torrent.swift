import Foundation
import BencodeKit
import FlyingSocks

public actor Torrent {
    public var isRunning: Bool = false {
        didSet {
            // TODO: convert to logger
            print("torrent with infohash \(self.infoHash) isRunning didSet")
            // Check that the value actually changed
            guard oldValue != isRunning else { return }

            trackerTask?.cancel()

            // Send start or stop tracker requests
            Task {
                try await performTrackerRequest(for: isRunning ? .start : .stop)
            }
        }
    }
    public let infoHash: InfoHash
    let torrentFile: TorrentFile
    let peerID: PeerID
    let port: UInt16
    let client: TorrentClient

    var connections: [PeerConnection] = []
    var fileIO: FileIO

    // TODO: better way to pass the peer ID around?
    init(infoHash: InfoHash, torrentFile: TorrentFileV1, client: TorrentClient, peerID: PeerID, port: UInt16) async throws {
        self.infoHash = infoHash
        self.torrentFile = TorrentFile(from: torrentFile)
        self.client = client
        // These could be gotten directly from the client, but it's a pain at least for the port because of concurrency
        self.peerID = peerID
        self.port = port
        // This can produce MultiFileIO; you just can't call a static method on the protocol type itself
        self.fileIO = try SingleFileIO.make(baseDirectory: URL.currentDirectory(), for: torrentFile)
        self.haves = try await self.fileIO.computeHaves(withHashes: self.torrentFile.pieces)
    }

    private enum Event: String {
        case start = "started"
        case stop = "stopped"
        case complete = "completed"
        case periodic = "empty"
    }

    private func buildTrackerRequest(for event: Event) throws -> URLRequest {
        Logger.shared.log("Building tracker request for \(event)", type: .trackerRequests)
        // TODO: handle picking the correct tracker
        guard var components = URLComponents(string: self.torrentFile.announce) else {
            Logger.shared.error("Cannot construct URLComponents from announce URL", type: .trackerRequests)
            throw TorrentError.invalidAnnounceURL(self.torrentFile.announce)
        }
        components.queryItems = [
            URLQueryItem(name: "port", value: String(self.port)),
            URLQueryItem(name: "uploaded", value: String(self.uploaded)),
            URLQueryItem(name: "downloaded", value: String(self.downloaded)),
            URLQueryItem(name: "left", value: String(self.left)),
        ]
        if event != .periodic {
            components.queryItems?.append(URLQueryItem(name: "event", value: event.rawValue))
        }
        if let trackerID = self.trackerID {
            // TODO: more logging?
            components.queryItems?.append(URLQueryItem(name: "trackerid", value: trackerID))
        }
        components.percentEncodedQueryItems?.append(contentsOf: [
            URLQueryItem(name: "info_hash", value: self.infoHash.percentEncoded()),
            URLQueryItem(name: "peer_id", value: self.peerID.percentEncoded()),
        ])
        guard let url = components.url else {
            Logger.shared.error("Cannot build URL from components", type: .trackerRequests)
            fatalError()
        }
        Logger.shared.log("Built URL \(url)", type: .trackerRequests)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    private func performTrackerRequest(for event: Event) async throws {
        Logger.shared.log("Performing tracker request for \(event)", type: .trackerRequests)
        let req = try buildTrackerRequest(for: event)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            Logger.shared.error("Tracker request failed with error: \(error)", type: .trackerRequests)
            fatalError("This shouldn't be an error at the end, but is for now")
        }

        guard let resp = resp as? HTTPURLResponse else {
            Logger.shared.error("Invalid (non-HTTP) \(event) tracker response", type: .trackerRequests)
            fatalError("Invalid tracker response to \(event) event")
        }

        guard resp.statusCode == 200 else {
            //TODO: also have to handle swapping trackers here
            Logger.shared.error("Non-200 \(event) tracker response", type: .trackerRequests)
            fatalError()
        }

        if let obj = try? BencodeDecoder().decode(FailedTrackerResponse.self, from: data) {
            Logger.shared.error("\(event) tracker request failed with error: \(obj.failureReason)", type: .trackerRequests)
            fatalError("Tracker request failed with error: \(obj.failureReason)")
        }

        guard let obj = try? BencodeDecoder().decode(TrackerResponse.self, from: data) else {
            Logger.shared.error("Cannot decode \(event) tracker response", type: .trackerRequests)
            fatalError()
        }

        Logger.shared.log("Tracker response: \(obj.complete) complete, \(obj.incomplete) incomplete, \(obj.peers.count) peers (first peer \(obj.peers.first?.ip):\(obj.peers.first?.port))", type: .trackerRequests)

        // This should maybe be made a little nicer
        if event != .stop {
            obj.peers.shuffled().prefix(upTo: 5).map { peerInfo in
                let peerID = PeerID(bytes: peerInfo.peerID)

                let addr: SocketAddress
                do {
                    addr = try .inet(ip4: peerInfo.ip, port: peerInfo.port)
                    Logger.shared.log("Created IPv4 SocketAddress for peer \(peerID)", type: .outgoingConnections)
                } catch {
                    do {
                        addr = try .inet6(ip6: peerInfo.ip, port: peerInfo.port)
                        Logger.shared.log("Created IPv6 SocketAddress for peer \(peerID)", type: .outgoingConnections)
                    } catch {
                        Logger.shared.warn("Unable to create SocketAddress for peer \(peerID)", type: .outgoingConnections)
                        return
                    }
                }
                self.makeConnection(to: peerID, at: addr)
            }
        }

        if let trackerID = obj.trackerID {
            Logger.shared.log("Tracker ID now set to \(trackerID)", type: .trackerRequests)
            self.trackerID = trackerID
        }

        if event == .start || event == .periodic {
            self.trackerTask?.cancel()
            self.trackerTask = Task {
                Logger.shared.log("Sleeping for \(obj.interval) seconds before next periodic request", type: .trackerRequests)
                try await Task.sleep(for: .seconds(obj.interval))
                try await performTrackerRequest(for: .periodic)
            }
        }
    }

    func makeConnection(to peerID: PeerID, at address: SocketAddress) {
        Task {
            let conn = try await PeerConnection.outgoing(to: peerID, at: address, for: self, asPartOf: self.client)
            defer { try? conn.close() }
            do {
                try await conn.runP2P()
                Logger.shared.log("[\(conn)] closed gracefully", type: .outgoingConnections)
            } catch {
                Logger.shared.warn("[\(conn)] closed with error \(error)", type: .outgoingConnections)
                throw error
            }
        }
    }

    func add(connection: PeerConnection) {
        self.connections.append(connection)
    }
    func remove(connection: PeerConnection) {
        self.connections.removeAll { pc in
            pc.uuid == connection.uuid
        }
    }

    var uploaded: Int = 0
    var downloaded: Int = 0
    var left: Int {
        0
    }

    private var trackerID: String?

    var haves: Haves

    private var trackerTask: Task<Void, Error>? = nil

    public func pause() {
        self.isRunning = false
    }

    public func resume() {
        self.isRunning = true
    }
}
