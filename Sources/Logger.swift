import Foundation

public struct Logger: Sendable {
    public enum LogType: CaseIterable, Sendable {
        case setup
        case incomingConnections
        case outgoingConnections
        case handshakes
        case peerCommunication
        case trackerRequests
        case verifyingPieces
    }

    static let shared = Logger(LogType.allCases)

    private let allowedLogTypes: [LogType]

    public init(_ allowedTypes: [LogType]) {
        self.allowedLogTypes = allowedTypes
    }

    func error(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print(msg)
        }
    }
    func warn(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print(msg)
        }
    }
    func log(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print(msg)
        }
    }
}
