import Foundation
import Crypto

protocol FileIO: Actor {
    init(baseDirectory: URL, for torrentFile: TorrentFile) throws

    func read(ofLength length: Int, fromPiece pieceIndex: UInt64, beginningAt byteOffset: UInt64) async throws -> Data
    func write(_ data: Data, inPiece pieceIndex: UInt64, beginningAt byteOffset: UInt64) async throws
    func computeHaves(withHashes pieces: [Data]) async throws -> Haves
}

extension FileIO {
    static func make(baseDirectory: URL, for torrentFile: TorrentFileV1) throws -> any FileIO {
        let t = TorrentFile(from: torrentFile)
        if torrentFile.info.length != nil {
            return try SingleFileIO(baseDirectory: baseDirectory, for: t)
        } else {
            return try MultiFileIO(baseDirectory: baseDirectory, for: t)
        }
    }
}

actor SingleFileIO: FileIO {
    private let fileHandle: FileHandle
    private let pieceLength: UInt64

    init(baseDirectory: URL, for torrentFile: TorrentFile) throws {
        let path = baseDirectory.appending(path: torrentFile.name)
        if FileManager.default.fileExists(atPath: path.path) {
            self.fileHandle = try FileHandle(forUpdating: path)
        } else {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            // I'd really like to do this in one call, but you apparently can't create files with a FileHandle
            // I could call `fopen`, which does create files, but then I need to convert the path to a C string
            FileManager.default.createFile(atPath: path.path, contents: nil)
            // The options are writing (write only), reading (read only), and updating (read and write)
            self.fileHandle = try FileHandle(forUpdating: path)
        }
        self.pieceLength = UInt64(torrentFile.pieceLength)
    }

    func read(ofLength length: Int, fromPiece pieceIndex: UInt64, beginningAt byteOffset: UInt64) async throws -> Data {
        let offset = (pieceIndex * pieceLength) + byteOffset
        try self.fileHandle.seek(toOffset: offset)
        guard let data = try self.fileHandle.read(upToCount: length) else {
            fatalError("Unable to read from file")
        }
        return data
    }

    func write(_ data: Data, inPiece pieceIndex: UInt64, beginningAt byteOffset: UInt64) async throws {
        let offset = (pieceIndex * pieceLength) + byteOffset
        try self.fileHandle.seek(toOffset: offset)
        try self.fileHandle.write(contentsOf: data)
    }

    func computeHaves(withHashes pieces: [Data]) throws -> Haves {
        Logger.shared.log("Checking resume data", type: .resuming)
        var haves = Haves.empty(ofLength: pieces.count)

        try self.fileHandle.seek(toOffset: 0)
        for i in 0..<pieces.count {
            guard let data = try self.fileHandle.read(upToCount: Int(self.pieceLength)) else {
                Logger.shared.warn("Unable to read from file; returning with \(haves.percentComplete, stringFormat: "%.2f")% recovered", type: .resuming)
                return haves
            }
            let hash = Data(Insecure.SHA1.hash(data: data))
            if hash == pieces[i] {
                haves[i] = true
            }
        }

        Logger.shared.log("Recovered \(haves.percentComplete, stringFormat: "%.2f")% of the torrent", type: .resuming)
        return haves
    }
}

actor MultiFileIO: FileIO {
    struct File {
        let length: Int
        let fileHandle: FileHandle
    }

    private let files: [File]
    private let pieceLength: UInt64

    init(baseDirectory: URL, for torrentFile: TorrentFile) throws {
        let rootDir = baseDirectory.appending(path: torrentFile.name)
        self.files = try torrentFile.files.map { file in
            var path = rootDir
            for segment in file.pathFromRoot {
                path.append(path: segment)
            }
            let handle: FileHandle
            if FileManager.default.fileExists(atPath: path.path) {
                handle = try FileHandle(forUpdating: path)
            } else {
                // See comments in SingleFileIO
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path.path, contents: nil)
                handle = try FileHandle(forUpdating: path)
            }
            return File(length: file.length, fileHandle: handle)
        }

        self.pieceLength = UInt64(torrentFile.pieceLength)
    }

    private func computeOffsets(pieceIndex: UInt64, byteOffset: UInt64) -> (Int, UInt64) {
        let offset = (pieceIndex * pieceLength) + byteOffset

        var idx = 0
        var cumulativeLength = 0
        while cumulativeLength < offset {
            cumulativeLength += files[idx].length
            idx += 1
        }

        cumulativeLength -= files[idx].length
        idx -= 1

        let inFileOffset = offset - UInt64(cumulativeLength)

        return (idx, inFileOffset)
    }

    func read(ofLength length: Int, fromPiece pieceIndex: UInt64, beginningAt byteOffset: UInt64) async throws -> Data {
        var (idx, inFileOffset) = computeOffsets(pieceIndex: pieceIndex, byteOffset: byteOffset)

        try files[idx].fileHandle.seek(toOffset: inFileOffset)
        guard var data = try files[idx].fileHandle.read(upToCount: length) else {
            fatalError("Unable to read from file")
        }

        while data.count < length {
            idx += 1
            try files[idx].fileHandle.seek(toOffset: 0)
            guard let tmp = try files[idx].fileHandle.read(upToCount: length - data.count) else {
                fatalError("Unable to read from file")
            }
            data.append(tmp)
        }

        return data
    }

    func write(_ data: Data, inPiece pieceIndex: UInt64, beginningAt byteOffset: UInt64) async throws {
        var (idx, inFileOffset) = computeOffsets(pieceIndex: pieceIndex, byteOffset: byteOffset)
        var data = data
        
        try files[idx].fileHandle.seek(toOffset: inFileOffset)

        let remainingSpaceInFile = files[idx].length - Int(inFileOffset)
        let tmp: Data
        if data.count > remainingSpaceInFile {
            tmp = data.prefix(upTo: remainingSpaceInFile)
            data = data.suffix(from: remainingSpaceInFile)
        } else {
            tmp = data
            data = Data()
        }

        try files[idx].fileHandle.write(contentsOf: tmp)

        while !data.isEmpty {
            idx += 1
            try files[idx].fileHandle.seek(toOffset: 0)

            let tmp: Data
            if data.count > files[idx].length {
                tmp = data.prefix(upTo: files[idx].length)
                data = data.suffix(from: files[idx].length)
            } else {
                tmp = data
                data = Data()
            }

            try files[idx].fileHandle.write(contentsOf: tmp)
        }
    }

    func computeHaves(withHashes pieces: [Data]) async throws -> Haves {
        Logger.shared.log("Checking resume data", type: .resuming)
        var haves = Haves.empty(ofLength: pieces.count)

        var data = Data()
        var fileIndex = 0
        try files[fileIndex].fileHandle.seek(toOffset: 0)
        for i in 0..<pieces.count {
            while data.count < Int(self.pieceLength) {
                let length = Int(self.pieceLength) - data.count
                guard let tmp = try files[fileIndex].fileHandle.read(upToCount: length) else {
                    Logger.shared.warn("Unable to read from file; returning with \(haves.percentComplete, stringFormat: "%.2f")% recovered", type: .resuming)
                    return haves
                }
                if tmp.count < length {
                    fileIndex += 1
                    try files[fileIndex].fileHandle.seek(toOffset: 0)
                }
                data.append(tmp)
            }
            let hash = Data(Insecure.SHA1.hash(data: data))
            haves[i] = hash == pieces[i]
            data = Data()
        }

        Logger.shared.log("Recovered \(haves.percentComplete, stringFormat: "%.2f")% of the torrent", type: .resuming)
        return haves
    }
}
