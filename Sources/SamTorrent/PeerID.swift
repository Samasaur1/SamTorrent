import Foundation

public struct PeerID: Equatable, Sendable, CustomStringConvertible {
    public static func random() -> PeerID {
        let versionData = "-SG0100-".data(using: .ascii)!
        let randomData = Data((0..<12).map { _ in UInt8.random(in: UInt8.min...UInt8.max) })
        let data = versionData + randomData
        return PeerID(bytes: data)
    }

    public let bytes: Data

    public var description: String {
        let chars = bytes.map { byte in
            Character(UnicodeScalar(byte))
        }
        return String(chars)
    }

    public func percentEncoded() -> String {
        bytes.percentEncoded()
    }
}
