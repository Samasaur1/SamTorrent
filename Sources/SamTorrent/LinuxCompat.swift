import Foundation

extension Measurement where UnitType == UnitInformationStorage {
    func desc() -> some CustomStringConvertible {
        #if canImport(Darwin)
        return self.formatted(.byteCount(style: .file))
        #else
        return self.description
        #endif
    }
}
