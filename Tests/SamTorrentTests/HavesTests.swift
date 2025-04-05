import Testing
import Foundation
@testable import SamTorrent

@Suite
struct HavesTests {
    @Suite
    struct ReversibleTests {
        @Test func lengthEight() {
            let bitfield = Data([0b01010110])

            let haves = Haves(fromBitfield: bitfield, length: 8)

            #expect(haves.repack() == bitfield)
        }

        @Test func lengthSixteen() {
            let bitfield = Data([0b01010110, 0b00110011])

            let haves = Haves(fromBitfield: bitfield, length: 16)

            #expect(haves.repack() == bitfield)
        }

        @Test func lengthTwelve() {
            let bitfield = Data([0b01010110, 0b00110000]) //last four bits ignored

            let haves = Haves(fromBitfield: bitfield, length: 12)

            // This only works because the last four bits are set to 0
            // They don't matter, so I'm making sure they match up with
            // the implementation of repack, even though this is normally
            // a bad way to do tests
            #expect(haves.repack() == bitfield)
        }
    }

    @Test(arguments: [5, 8, 32, 100])
    func fullIsComplete(length: Int) {
        let bitField = Haves.full(ofLength: length)

        #expect(bitField.isComplete)
    }

    @Test func fullEquivalentToHandCreated() {
        let full = Haves.full(ofLength: 12)
        let manual = Haves(fromBitfield: Data([.max, 0b1111_0110]), length: 12)

        #expect(full == manual)
    }
}
