import Foundation

// From Gauck (2022). Used with permission.
struct /*The*/ Haves /*And The Have-Nots*/ : Equatable {
    internal private(set) var arr: [Bool] = []
    let length: Int
    //This MUST NOT be a slice, but slices can be usable if wrapped in Data
    //  see https://forums.swift.org/t/is-this-a-flaw-in-data-design/12812
    init(fromBitfield bitfield: Data, length: Int) {
        for i in 0..<length {
            let byte = bitfield[i/8]
            let val = byte & (UInt8(0b10000000) >> (i % 8))
            arr.append(val != 0)
        }
        self.length = length
    }
    static func empty(ofLength length: Int) -> Haves {
        return Haves(fromBitfield: Data(repeating: 0, count: (length/8)+1), length: length)
    }
    static func full(ofLength length: Int) -> Haves {
        return Haves(fromBitfield: Data(repeating: .max, count: (length/8)+1), length: length)
    }
    subscript(index: Int) -> Bool {
        get {
            arr[index]
        }
        set {
            arr[index] = newValue
        }
    }
    subscript(index: UInt32) -> Bool {
        get {
            self[Int(index)]
        }
        set {
            self[Int(index)] = newValue
        }
    }

    func repack() -> Data {
        var data = Data()
        var currentByte = UInt8(0)
        var bitInByte = 7
        for val in arr {
            if bitInByte < 0 {
                data.append(currentByte)
                currentByte = 0
                bitInByte = 7
            }
            guard val else {
                bitInByte -= 1
                continue
            }
            currentByte |= 1 << bitInByte
            bitInByte -= 1
        }
        if bitInByte >= -1 {
            data.append(currentByte)
        }
        return data
    }
    func makeMessage() -> Data {
        let packed = repack()
        let msg = Data(from: UInt32(1 + packed.count).bigEndian) + [5] + packed
        return msg
    }

    func newPieces(fromOld old: Haves) -> [UInt32] {
//            var indices = [UInt32]()
//            zip(arr, old.arr).enumerated().filter { (idx, tup) in
//                let (newVal, oldVal) = tup
//                if newVal != oldVal {
//                    indices.append(UInt32(idx))
//                }
//            }
//            return indices
        var indices = [UInt32]()
        for i in 0..<arr.count {
            if arr[i] && !old.arr[i] {
                indices.append(UInt32(i))
            }
        }
        return indices
    }

    var isComplete: Bool {
        !arr.contains(false)
    }

    var bitString: String {
        arr.map { $0 ? "1" : "0"}.joined(separator: "")
    }

    var fractionComplete: Double {
        Double(self.arr.count { $0 }) / Double(length)
    }

    var percentString: String {
        fractionComplete.formatted(.percent.precision(.fractionLength(2)))
    }
}
