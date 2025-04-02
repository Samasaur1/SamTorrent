import Foundation
import Rainbow

public struct Logger: Sendable {
    public enum LogType: CaseIterable, Sendable {
        case setup
        case incomingConnections
        case outgoingConnections
        case handshakes
        case peerCommunication
        case trackerRequests
        case verifyingPieces

        var logPrefix: String {
            switch self {
            case .setup:
                return "SETUP"
            case .incomingConnections:
                return "RECVX"
            case .outgoingConnections:
                return "SENDX"
            case .handshakes:
                return "SHAKE"
            case .peerCommunication:
                return "PEERX"
            case .trackerRequests:
                return "TRACK"
            case .verifyingPieces:
                return "VERFY"
            }
        }
    }

    static let shared = Logger(LogType.allCases)

    private let allowedLogTypes: [LogType]

    public init(_ allowedTypes: [LogType]) {
        self.allowedLogTypes = allowedTypes
    }

    func error(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print("[\(type.logPrefix)]:".bold.red, msg)
        }
    }
    func warn(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print("[\(type.logPrefix)]:".bold.yellow, msg)
        }
    }
    func log(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print("[\(type.logPrefix)]:".bold, msg)
        }
    }
}
