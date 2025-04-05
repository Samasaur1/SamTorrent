import Foundation
import FlyingSocks

// https://stackoverflow.com/a/40089462
extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let hexDigits = options.contains(.upperCase) ? "0123456789ABCDEF" : "0123456789abcdef"
        if #available(macOS 11.0, iOS 14.0, watchOS 7.0, tvOS 14.0, *) {
            let utf8Digits = Array(hexDigits.utf8)
            return String(unsafeUninitializedCapacity: 2 * self.count) { (ptr) -> Int in
                var p = ptr.baseAddress!
                for byte in self {
                    p[0] = utf8Digits[Int(byte / 16)]
                    p[1] = utf8Digits[Int(byte % 16)]
                    p += 2
                }
                return 2 * self.count
            }
        } else {
            let utf16Digits = Array(hexDigits.utf16)
            var chars: [unichar] = []
            chars.reserveCapacity(2 * self.count)
            for byte in self {
                chars.append(utf16Digits[Int(byte / 16)])
                chars.append(utf16Digits[Int(byte % 16)])
            }
            return String(utf16CodeUnits: chars, count: chars.count)
        }
    }

    //from https://stackoverflow.com/a/38024025/8387516
    init<T>(from value: T) {
        self = Swift.withUnsafeBytes(of: value) { Data($0) }
    }


    func to<T>(type: T.Type) -> T? where T: ExpressibleByIntegerLiteral {
        var value: T = 0
        guard count == MemoryLayout.size(ofValue: value) else { return nil }
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0) }
        return value
    }

    func percentEncoded() -> String {
        self.map { byte in
            switch byte {
            case 126:
                return "~"
            case 46:
                return "."
            case 95:
                return "_"
            case 45:
                return "-"
            case let x where x >= 48 && x <= 57: // [0-9]
                //return Character(UnicodeScalar(x))
                return "\(x-48)"
            case let x where x >= 65 && x <= 90: //[A-Z]
                return String(Character(UnicodeScalar(x)))
            case let x where x >= 97 && x <= 122: //[a-z]
                return String(Character(UnicodeScalar(x)))
            default:
                return String(format: "%%%02x", byte)
                //equivalent to String(byte, radix: 16, uppercase: true) but with padding
            }
        }.joined(separator: "")
    }
}

// https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
extension Sequence {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var values = [T]()

        for element in self {
            try await values.append(transform(element))
        }

        return values
    }
    //
    // func concurrentMap<T: Sendable>(
    //     _ transform: @escaping (Element) async throws -> T
    // ) async rethrows -> [T] {
    //     let tasks = map { element in
    //         Task {
    //             try await transform(element)
    //         }
    //     }
    //
    //     return try await tasks.asyncMap { task in
    //         try await task.value
    //     }
    // }
}

extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, stringFormat: String) {
        appendLiteral(String(format: stringFormat, value))
    }
}

enum SocketAddressError: Swift.Error {
    case unknownAddress
}
extension SocketAddress {
    func toString() throws -> String {
        let storage = self.makeStorage()
        let addr = try Socket.makeAddress(from: storage)
        switch addr {
        case let .ip4(ip, port: port), let .ip6(ip, port: port):
            return "\(ip):\(port)"
        default:
            throw SocketAddressError.unknownAddress
        }
    }
}
