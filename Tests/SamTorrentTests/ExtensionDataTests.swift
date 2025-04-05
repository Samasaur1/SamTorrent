import Testing
import Foundation
@testable import SamTorrent

@Suite
struct ExtensionDataTests {
    @Test func reversible() {
        let data = Data([0, 1, 2, 3, 4, 5, 6, 7])

        let ext = ExtensionData(from: data)

        #expect(ext.bytes == data)
    }

    @Test func emptyOptionSetProducesZeroBytes() {
        let ext: ExtensionData = []

        #expect(ext.bytes == Data([0,0,0,0,0,0,0,0]))
    }

    @Test func extensionProtocolBitIsCorrect() {
        let data = Data([0, 0, 0, 0, 0, 0x10, 0, 0])

        #expect(ExtensionData.extension.bytes == data)

        let ext = ExtensionData(from: data)

        #expect(ext == .extension)
    }

    @Test func fastExtensionBitIsCorrect() {
        let data = Data([0, 0, 0, 0, 0, 0, 0, 0x04])

        #expect(ExtensionData.fast.bytes == data)

        let ext = ExtensionData(from: data)

        #expect(ext == .fast)
    }

    @Test func dhtBitIsCorrect() {
        let data = Data([0, 0, 0, 0, 0, 0, 0, 0x01])

        #expect(ExtensionData.dht.bytes == data)

        let ext = ExtensionData(from: data)

        #expect(ext == .dht)
    }

    @Test func compositionOfFastAndDHT() {
        let data = Data([0, 0, 0, 0, 0, 0, 0, 0x05])

        let correct: ExtensionData = [.dht, .fast]

        #expect(correct.bytes == data)

        let ext = ExtensionData(from: data)

        #expect(ext == correct)
    }
}
