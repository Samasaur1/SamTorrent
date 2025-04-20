import Foundation

struct ExtensionData: OptionSet {
    let rawValue: UInt64

    // I'd like to use bit shifting, but I was running into weird errors
    // that I think were due to endianness
    static let dht: ExtensionData = ExtensionData(from: Data([0,0,0,0,0,0,0,0x01])) // BEP0005
    static let fast: ExtensionData = ExtensionData(from: Data([0,0,0,0,0,0,0,0x04])) // BEP0006
    static let `extension`: ExtensionData = ExtensionData(from: Data([0,0,0,0,0,0x10,0,0])) //BEP0010

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
