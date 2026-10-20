import Foundation

/// A raw DEFLATE (RFC 1951) decoder with a hard output ceiling.
///
/// The package deliberately carries its own decoder instead of depending on
/// zlib or Apple's Compression framework: the reader must build and behave the
/// same way on macOS and Linux, and the output ceiling is the decompression-bomb
/// defence (report 10, T-04) — it has to live inside the decode loop, not after
/// it, or a bomb is already in memory by the time it is noticed.
enum InflateFailure: Error {
    case truncated
    case invalidBlockType
    case invalidHuffmanTable
    case invalidStoredBlock
    case invalidDistance
    case invalidCode
    case outputLimit
}

/// LSB-first bit reader over the compressed bytes.
struct BitReader {
    let bytes: [UInt8]
    var bitOffset: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readBit() throws -> Int {
        let byteIndex = bitOffset >> 3
        guard byteIndex < bytes.count else { throw InflateFailure.truncated }
        let bit = (Int(bytes[byteIndex]) >> (bitOffset & 7)) & 1
        bitOffset += 1
        return bit
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        var shift = 0
        for _ in 0..<count {
            value |= try readBit() << shift
            shift += 1
        }
        return value
    }

    mutating func alignToByte() {
        bitOffset = (bitOffset + 7) & ~7
    }

    mutating func readByte() throws -> UInt8 {
        let byteIndex = bitOffset >> 3
        guard byteIndex < bytes.count else { throw InflateFailure.truncated }
        bitOffset += 8
        return bytes[byteIndex]
    }
}

/// A canonical Huffman decoding table, built the way zlib's `inflate_table`
/// builds its code space: per-length counts, first code per length, and the
/// symbol array in code order.
struct HuffmanTable {
    private let counts: [Int]
    private let symbols: [Int]
    private let maxBits: Int

    init(codeLengths: [Int], maxBits: Int) throws {
        self.maxBits = maxBits
        var counts = [Int](repeating: 0, count: maxBits + 1)
        for length in codeLengths {
            guard length >= 0, length <= maxBits else { throw InflateFailure.invalidHuffmanTable }
            counts[length] += 1
        }
        // Length zero means "unused symbol", not a code.
        counts[0] = 0

        var remaining = 1
        for bits in 1...maxBits {
            remaining <<= 1
            remaining -= counts[bits]
            guard remaining >= 0 else { throw InflateFailure.invalidHuffmanTable }
        }

        var offsets = [Int](repeating: 0, count: maxBits + 2)
        for bits in 1...maxBits {
            offsets[bits + 1] = offsets[bits] + counts[bits]
        }

        var symbols = [Int](repeating: 0, count: codeLengths.count)
        for (symbol, length) in codeLengths.enumerated() where length != 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }

        self.counts = counts
        self.symbols = symbols
    }

    /// Decodes one symbol bit by bit. At most 15 iterations, no lookahead table.
    func decode(_ reader: inout BitReader) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...maxBits {
            code |= try reader.readBit()
            let count = counts[length]
            if code - first < count {
                let symbol = symbols[index + (code - first)]
                return symbol
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw InflateFailure.invalidCode
    }
}

struct Inflater {
    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    private static let fixedLiteralTable = try? HuffmanTable(
        codeLengths: (0..<288).map { symbol -> Int in
            switch symbol {
            case 0...143: return 8
            case 144...255: return 9
            case 256...279: return 7
            default: return 8
            }
        },
        maxBits: 15
    )
    private static let fixedDistanceTable = try? HuffmanTable(
        codeLengths: [Int](repeating: 5, count: 32),
        maxBits: 15
    )

    private var reader: BitReader
    private var output: [UInt8] = []
    private let outputLimit: Int
    private let entryName: String

    init(input: Data, outputLimit: Int, entryName: String) {
        self.reader = BitReader(bytes: [UInt8](input))
        self.outputLimit = outputLimit
        self.entryName = entryName
    }

    private mutating func append(_ byte: UInt8) throws {
        guard output.count < outputLimit else { throw InflateFailure.outputLimit }
        output.append(byte)
    }

    mutating func run() throws -> Data {
        do {
            var isFinal = false
            while !isFinal {
                isFinal = try reader.readBit() == 1
                let blockType = try reader.readBits(2)
                switch blockType {
                case 0:
                    try inflateStoredBlock()
                case 1:
                    guard let literal = Inflater.fixedLiteralTable,
                          let distance = Inflater.fixedDistanceTable else {
                        throw InflateFailure.invalidHuffmanTable
                    }
                    try inflateHuffmanBlock(literal: literal, distance: distance)
                case 2:
                    try inflateDynamicBlock()
                default:
                    throw InflateFailure.invalidBlockType
                }
            }
            return Data(output)
        } catch let failure as InflateFailure {
            if case .outputLimit = failure {
                throw IPAError.decompressionLimitExceeded(name: entryName, limit: outputLimit)
            }
            throw IPAError.corruptDeflateStream(name: entryName)
        }
    }

    private mutating func inflateStoredBlock() throws {
        reader.alignToByte()
        let length = try reader.readBits(16)
        let complement = try reader.readBits(16)
        guard length == ((~complement) & 0xFFFF) else { throw InflateFailure.invalidStoredBlock }
        for _ in 0..<length {
            try append(try reader.readByte())
        }
    }

    private mutating func inflateDynamicBlock() throws {
        let literalCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw InflateFailure.invalidHuffmanTable }

        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[Inflater.codeLengthOrder[index]] = try reader.readBits(3)
        }
        let codeLengthTable = try HuffmanTable(codeLengths: codeLengthLengths, maxBits: 7)

        let total = literalCount + distanceCount
        var lengths: [Int] = []
        lengths.reserveCapacity(total)
        while lengths.count < total {
            let symbol = try codeLengthTable.decode(&reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw InflateFailure.invalidHuffmanTable }
                let repeats = try reader.readBits(2) + 3
                lengths.append(contentsOf: repeatElement(previous, count: repeats))
            case 17:
                let repeats = try reader.readBits(3) + 3
                lengths.append(contentsOf: repeatElement(0, count: repeats))
            case 18:
                let repeats = try reader.readBits(7) + 11
                lengths.append(contentsOf: repeatElement(0, count: repeats))
            default:
                throw InflateFailure.invalidHuffmanTable
            }
            guard lengths.count <= total else { throw InflateFailure.invalidHuffmanTable }
        }

        let literalLengths = Array(lengths[0..<literalCount])
        let distanceLengths = Array(lengths[literalCount...])
        // 256 is the end-of-block symbol; a block that cannot end is invalid.
        guard literalLengths.count > 256, literalLengths[256] != 0 else {
            throw InflateFailure.invalidHuffmanTable
        }
        let literalTable = try HuffmanTable(codeLengths: literalLengths, maxBits: 15)
        let distanceTable = try HuffmanTable(codeLengths: distanceLengths, maxBits: 15)
        try inflateHuffmanBlock(literal: literalTable, distance: distanceTable)
    }

    private mutating func inflateHuffmanBlock(literal: HuffmanTable, distance: HuffmanTable) throws {
        while true {
            let symbol = try literal.decode(&reader)
            if symbol < 256 {
                try append(UInt8(symbol))
                continue
            }
            if symbol == 256 {
                return
            }

            let lengthIndex = symbol - 257
            guard lengthIndex < Inflater.lengthBase.count else { throw InflateFailure.invalidCode }
            var length = Inflater.lengthBase[lengthIndex]
            let lengthExtra = Inflater.lengthExtra[lengthIndex]
            if lengthExtra > 0 {
                length += try reader.readBits(lengthExtra)
            }

            let distanceSymbol = try distance.decode(&reader)
            guard distanceSymbol < Inflater.distanceBase.count else { throw InflateFailure.invalidDistance }
            var back = Inflater.distanceBase[distanceSymbol]
            let distanceExtra = Inflater.distanceExtra[distanceSymbol]
            if distanceExtra > 0 {
                back += try reader.readBits(distanceExtra)
            }
            guard back >= 1, back <= output.count else { throw InflateFailure.invalidDistance }

            let start = output.count - back
            for offset in 0..<length {
                try append(output[start + offset])
            }
        }
    }
}
