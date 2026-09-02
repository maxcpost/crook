import Foundation

/// Per-file byte state, recorded on open and reproduced exactly on save.
///
/// This is the mechanism behind Crook's one non-negotiable claim. Measured over
/// the frozen 270-file fixture: 8 files use CRLF, 15 have no final newline, 68
/// carry trailing whitespace, 0 have a BOM, 0 have a lone CR, 0 use leading tabs
/// (docs/09-corpus-census.md).
struct ByteProfile: Equatable {
    enum LineEnding: String, Equatable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    var lineEnding: LineEnding
    var hasFinalNewline: Bool
    var bom: Data?
    var encoding: String.Encoding

    /// True when the file mixes line endings. Such a file cannot be round-tripped
    /// by re-expanding a single ending, so the writer must refuse to normalise it.
    var mixedLineEndings: Bool
}

enum ByteProfileError: Error, CustomStringConvertible {
    case undecodable(triedUTF8: Bool)
    case unencodable(String.Encoding)

    var description: String {
        switch self {
        case .undecodable:
            return "File is not valid UTF-8 and no fallback encoding produced text."
        case .unencodable(let e):
            return "The edited text cannot be written back as \(e). Saving would truncate the file."
        }
    }
}

/// Decodes file bytes into the canonical LF-only buffer, capturing everything
/// needed to reconstruct the original byte-for-byte.
///
/// The canonical buffer is LF-only and UTF-16 indexed. CRLF is normalised HERE,
/// at the Swift boundary, and re-expanded in `encode`. `EditorState.lineSeparator`
/// is never set on the CodeMirror side: CM6 stores a CRLF as ONE unit while
/// NSMutableString stores two, which diverges the two coordinate spaces. Measured:
/// doc.length matched source length on only 262 of 270 fixture files under that
/// arrangement, and a Swift insert at offset 144 in a CRLF command file landed
/// two characters late.
enum ByteCodec {

    static let bomUTF8 = Data([0xEF, 0xBB, 0xBF])
    static let bomUTF16LE = Data([0xFF, 0xFE])
    static let bomUTF16BE = Data([0xFE, 0xFF])
    static let bomUTF32LE = Data([0xFF, 0xFE, 0x00, 0x00])
    static let bomUTF32BE = Data([0x00, 0x00, 0xFE, 0xFF])

    /// - Returns: the canonical LF-only text, and the profile needed to re-encode.
    static func decode(_ data: Data) throws -> (text: NSMutableString, profile: ByteProfile) {
        // UTF-32LE must be sniffed before UTF-16LE — its BOM has the UTF-16LE
        // BOM as a prefix.
        var body = data
        var bom: Data?
        var encoding: String.Encoding = .utf8

        if data.starts(with: bomUTF32LE) { bom = bomUTF32LE; encoding = .utf32LittleEndian }
        else if data.starts(with: bomUTF32BE) { bom = bomUTF32BE; encoding = .utf32BigEndian }
        else if data.starts(with: bomUTF8) { bom = bomUTF8; encoding = .utf8 }
        else if data.starts(with: bomUTF16LE) { bom = bomUTF16LE; encoding = .utf16LittleEndian }
        else if data.starts(with: bomUTF16BE) { bom = bomUTF16BE; encoding = .utf16BigEndian }

        if let b = bom { body = data.dropFirst(b.count) }

        var raw: String
        if let decoded = String(data: body, encoding: encoding) {
            raw = decoded
        } else {
            // Fall back only for files with no BOM claiming UTF-8.
            guard bom == nil, let latin = String(data: body, encoding: .isoLatin1) else {
                throw ByteProfileError.undecodable(triedUTF8: true)
            }
            raw = latin
            encoding = .isoLatin1
        }

        let crlfCount = raw.components(separatedBy: "\r\n").count - 1
        let strippedCR = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let loneCRCount = strippedCR.components(separatedBy: "\r").count - 1
        let lfCount = strippedCR.components(separatedBy: "\n").count - 1 - crlfCount

        let ending: ByteProfile.LineEnding
        if crlfCount > 0 && lfCount == 0 && loneCRCount == 0 { ending = .crlf }
        else if loneCRCount > 0 && crlfCount == 0 && lfCount == 0 { ending = .cr }
        else { ending = .lf }

        let kinds = [crlfCount > 0, lfCount > 0, loneCRCount > 0].filter { $0 }.count
        let mixed = kinds > 1

        // Canonicalise: every ending becomes LF.
        var canonical = strippedCR
        if loneCRCount > 0 { canonical = canonical.replacingOccurrences(of: "\r", with: "\n") }

        let profile = ByteProfile(
            lineEnding: ending,
            hasFinalNewline: canonical.hasSuffix("\n"),
            bom: bom,
            encoding: encoding,
            mixedLineEndings: mixed
        )
        return (NSMutableString(string: canonical), profile)
    }

    /// Reconstructs file bytes from the canonical buffer and its profile.
    ///
    /// A scaffold appending a newline to a file that did not have one is the
    /// sneakiest way to lose byte stability, because it reads as an addition
    /// rather than a rewrite. Every insertion path routes through here.
    static func encode(_ text: NSString, profile: ByteProfile) throws -> Data {
        var s = text as String

        if profile.hasFinalNewline {
            if !s.hasSuffix("\n") { s += "\n" }
        } else {
            while s.hasSuffix("\n") { s.removeLast() }
        }

        // A file that mixed endings on read is never normalised on write — we
        // cannot reconstruct which line had which, so LF is left as-is and the
        // caller is expected to have surfaced the condition.
        if !profile.mixedLineEndings {
            switch profile.lineEnding {
            case .lf: break
            case .crlf: s = s.replacingOccurrences(of: "\n", with: "\r\n")
            case .cr: s = s.replacingOccurrences(of: "\n", with: "\r")
            }
        }

        // A nil here used to coalesce to Data(), which WRITES A ZERO-BYTE
        // FILE. A file that decoded as isoLatin1 cannot hold a character above
        // U+00FF, so typing one emoji into it truncated it to nothing. For an
        // app whose one claim is byte fidelity, refuse the save instead.
        guard let body = s.data(using: profile.encoding) else {
            throw ByteProfileError.unencodable(profile.encoding)
        }
        var out = Data()
        if let b = profile.bom { out.append(b) }
        out.append(body)
        return out
    }
}
