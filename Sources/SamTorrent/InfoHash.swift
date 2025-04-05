import Foundation

public enum InfoHash: Hashable, Sendable, CustomStringConvertible {
    case v1(Data)

    public var description: String {
        switch self {
        case .v1(let data):
            return data.hexEncodedString()
        }
    }

    var bytes: Data {
        switch self {
        case .v1(let data):
            return data
        }
    }

    func percentEncoded() -> String {
        bytes.percentEncoded()
    }
}
