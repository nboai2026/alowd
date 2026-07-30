import Foundation

/// Shared JSON coding for Alowd's on-disk stores. Dates are encoded as the
/// bit pattern of their time interval since the reference date; keep this
/// format so existing profile and history files stay readable.
public enum AlowdJSONCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let bitPattern = try container.decode(UInt64.self)
            return Date(timeIntervalSinceReferenceDate: TimeInterval(bitPattern: bitPattern))
        }
        return decoder
    }
}

/// Well-known locations inside a Alowd profile directory.
public enum AlowdPaths {
    /// The single root used for local WhisperKit model and tokenizer files.
    public static func whisperKitModelRoot(profileRoot: URL) -> URL {
        profileRoot.appendingPathComponent("models/whisperkit", isDirectory: true)
    }
}
