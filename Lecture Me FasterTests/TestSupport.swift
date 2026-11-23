import Foundation
@testable import Lecture_Me_Faster

// Shorthands the tests use. They were once in the app itself, where nothing but the tests called them.

extension FileToAI {
    /// A request with the system prompt for `detail`.
    static func request(for parts: [Part], config: AIConfiguration, detail: NoteDetail = .detailed) throws -> URLRequest {
        try request(for: parts, config: config, system: systemPrompt(detail: detail))
    }
}

extension VideoToFrames {
    /// `isCovered` against one later frame.
    static func isAddition(
        _ earlier: [UInt8], to later: [UInt8], width: Int = Signature.width, height: Int = Signature.height,
        ignoring motion: Motion, earlierText: String? = nil, laterText: String? = nil
    ) -> Bool {
        isCovered(earlier, by: [later], width: width, height: height, ignoring: motion, earlierText: earlierText, nextText: laterText)
    }
}
