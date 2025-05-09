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
        case resuming

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
            case .resuming:
                return "RESUM"
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
            // print("[\(type.logPrefix)]:".bold.red, msg)
            print("[\(Date()) \(type.logPrefix.bold.red)]: \(msg)")
        }
    }
    func warn(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            // print("[\(type.logPrefix)]:".bold.yellow, msg)
            print("[\(Date()) \(type.logPrefix.bold.yellow)]: \(msg)")
        }
    }
    func log(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            // print("[\(type.logPrefix)]:".bold, msg)
            print("[\(Date()) \(type.logPrefix.bold)]: \(msg)")
        }
    }
}
