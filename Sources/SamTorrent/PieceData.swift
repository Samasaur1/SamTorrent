import Foundation
import Crypto

// From Gauck (2022). Used with permission.
struct PieceRequest: Equatable, Hashable, Sendable {
    let index: UInt32
    let offset: UInt32
    let length: UInt32

    func makeMessage() -> Data {
        return Data(from: UInt32(13).bigEndian) + [6] + Data(from: index.bigEndian) + Data(from: offset.bigEndian) + Data(from: length.bigEndian)
    }
}

struct PieceData {
    struct WrittenSegment { //TODO: make private
        static let MAX_LENGTH: UInt32 = 1 << 14 //2^14; 16KB
        let offset: UInt32
        let length: UInt32
        var data = Data()
        init(_ d: Data, at offset: UInt32, of length: UInt32) {
            self.data = d
            self.offset = offset
            self.length = length
        }

        func before(subsequent: WrittenSegment) -> WrittenSegment {
            precondition(self.offset + self.length == subsequent.offset)
            return .init(self.data + subsequent.data, at: self.offset, of: self.length + subsequent.length)
        }
        func after(previous: WrittenSegment) -> WrittenSegment {
            precondition(previous.offset + previous.length == self.offset)
            return .init(previous.data + self.data, at: previous.offset, of: previous.length + self.length)
        }
    }
    let idx: UInt32
    private let size: UInt32
    private let pieceHash: Data
    private var writtenSegments: [WrittenSegment] = []
    var totalData: UInt32 {
        writtenSegments.map(\.length).reduce(0, +)
    }

    init(idx: UInt32, size: UInt32, pieceHash: Data) {
        self.idx = idx
        self.size = size
        self.pieceHash = pieceHash
    }

    mutating func receive(_ data: Data, at offset: UInt32, in piece: UInt32) {
        var segment = WrittenSegment(data, at: offset, of: UInt32(data.count))
        if let idx = writtenSegments.firstIndex(where: { $0.offset + $0.length == segment.offset }) {
            let previous = writtenSegments.remove(at: idx)
            segment = segment.after(previous: previous)
        }
        if let idx = writtenSegments.firstIndex(where: { segment.offset + segment.length == $0.offset }) {
            let subsequent = writtenSegments.remove(at: idx)
            segment = segment.before(subsequent: subsequent)
        }
        writtenSegments.append(segment)

        writtenSegments.sort(by: { $0.offset < $1.offset })
    }

    func nextFiveRequests() -> [PieceRequest] {
//            guard let first = writtenSegments.first else {
//                //no segments
//                let fullPieces = WrittenSegment.MAX_LENGTH/size
//                if fullPieces >= 5 {
//                    var requests = [PieceRequest]()
//                    var offset = UInt32(0)
//                    for _ in 0..<5 {
//                        requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                        offset += WrittenSegment.MAX_LENGTH
//                    }
//                    return requests
//                } else { //fullPieces < 5
//                    var requests = [PieceRequest]()
//                    var offset = UInt32(0)
//                    for _ in 0..<fullPieces {
//                        requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                        offset += WrittenSegment.MAX_LENGTH
//                    }
//                    if offset < size {
//                        requests.append(.init(idx: idx, begin: offset, length: size - offset))
//                    }
//                    return requests
//                }
//            }
//            var requests = [PieceRequest]()
//            //first == first segment
//            guard first.offset == 0 else {
//                var offset = UInt32(0)
//                while offset + WrittenSegment.MAX_LENGTH <= first.offset {
//                    requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                    offset += WrittenSegment.MAX_LENGTH
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//                if offset < first.offset {
//                    requests.append(.init(idx: idx, begin: offset, length: first.offset - offset))
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//            }
//            var offset = first.offset + first.length
//            guard let next = writtenSegments.dropFirst().first else {
//                //only one piece
//                while offset + WrittenSegment.MAX_LENGTH <= size {
//                    requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                    offset += WrittenSegment.MAX_LENGTH
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//                if offset < size {
//                    requests.append(.init(idx: idx, begin: offset, length: size - offset))
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//                return requests
//            }
//            //precondition(offset < next.offset, "These two segments should have been joined!")
//            while offset + WrittenSegment.MAX_LENGTH <= next.offset {
//                requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                offset += WrittenSegment.MAX_LENGTH
//                if requests.count == 5 {
//                    return requests
//                }
//            }
//            if offset < next.offset {
//                requests.append(.init(idx: idx, begin: offset, length: next.offset - offset))
//                if requests.count == 5 {
//                    return requests
//                }
//            }
        var offset = UInt32(0)
        var iter = writtenSegments.makeIterator()
        var requests = [PieceRequest]()
        while true {
            guard let next = iter.next() else {
                while offset + WrittenSegment.MAX_LENGTH <= size {
                    requests.append(.init(index: idx, offset: offset, length: WrittenSegment.MAX_LENGTH))
                    offset += WrittenSegment.MAX_LENGTH
                    if requests.count == 5 {
                        return requests
                    }
                }
                if offset < size {
                    requests.append(.init(index: idx, offset: offset, length: size - offset))
                    if requests.count == 5 {
                        return requests
                    }
                }
                return requests
            }
            if offset > next.offset {
                print("---- offset > next.offset")
                dump(writtenSegments)
                dump(requests)
                print("offset=\(offset),next.offset=\(next.offset)")
                if offset >= next.offset + next.length {
                    print("next piece subset of this piece; skipping")
                    continue
                }
                fatalError("Offset > next.offset when queueing requests; should never happen")
                //an actual overlap of pieces
                //maybe if we get requests out of order?
            }
            if offset == next.offset {
                //This better only happen for the first piece, or they should have been joined
                precondition(offset == 0)
                offset = next.length
                continue
            }
            //offset < next.offset
            while offset + WrittenSegment.MAX_LENGTH <= next.offset {
                requests.append(.init(index: idx, offset: offset, length: WrittenSegment.MAX_LENGTH))
                offset += WrittenSegment.MAX_LENGTH
                if requests.count == 5 {
                    return requests
                }
            }
            if offset < next.offset {
                requests.append(.init(index: idx, offset: offset, length: next.offset - offset))
                offset = next.offset + next.length
                if requests.count == 5 {
                    return requests
                }
            }
        }
    }

    var isComplete: Bool {
        guard writtenSegments.count == 1 else {
            return false
        }
        let seg = writtenSegments[0]
        // logger.log("Piece \(idx) is\(seg.offset == 0 && seg.length == size ? "" : " not") complete", type: .verifyingPieces)
        return seg.offset == 0 && seg.length == size
    }

    func verify() -> Data? {
        // logger.log("Attempting to verify piece \(idx)", type: .verifyingPieces)
        guard isComplete else {
            return nil
        }
        let hash = Data(Insecure.SHA1.hash(data: writtenSegments[0].data))
        // logger.log("Piece \(idx) is\(hash == infoHash ? "" : " not") verified", type: .verifyingPieces)
        if hash == pieceHash {
            return writtenSegments[0].data
        }
        return nil
    }
}
