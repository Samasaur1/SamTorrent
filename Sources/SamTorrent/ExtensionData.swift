import Foundation

struct ExtensionData: OptionSet {
    let rawValue: UInt64

    static let dht: ExtensionData = ExtensionData(rawValue: 1 << 0) // BEP0005
    static let fast: ExtensionData = ExtensionData(rawValue: 1 << 2) // BEP0006
    static let `extension`: ExtensionData = ExtensionData(rawValue: 1 << 20) //BEP0010

    static let supportedByMe: ExtensionData = []
}
extension ExtensionData: CustomStringConvertible {
    init(from bytes: Data) {
        rawValue = bytes.to(type: UInt64.self)!
        // TODO: test this
    }

    var bytes: Data {
        Data(from: self.rawValue)
        // TODO: test this
    }

    var description: String {
        "ExtensionData(dht: \(self.contains(.dht)), fast: \(self.contains(.fast)), extension: \(self.contains(.extension)))"
    }
}
