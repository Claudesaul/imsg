import Foundation
import IMsgCore

/// Shared CLI/RPC contract. Validate every part before staging any files.
enum MultipartParts {
  static func validate(_ rawParts: [[String: Any]]) throws -> [[String: Any]] {
    guard !rawParts.isEmpty, rawParts.count <= 20 else {
      throw RPCError.invalidParams("parts must contain between 1 and 20 text or file parts")
    }
    return try rawParts.enumerated().map { index, rawPart in
      let part = try RPCParameters(
        rawPart, method: "send.multipart parts[\(index)]",
        supportedKeys: ["text", "file", "text_formatting", "textFormatting"])
      guard part.contains("text") != part.contains("file") else {
        throw RPCError.invalidParams("parts[\(index)] must contain exactly one of text or file")
      }
      if part.contains("file") {
        guard let file = try part.string("file"), !file.isEmpty else {
          throw RPCError.invalidParams("parts[\(index)].file must be a non-empty string")
        }
        guard !part.contains("text_formatting"), !part.contains("textFormatting") else {
          throw RPCError.invalidParams("file parts cannot contain text formatting")
        }
        return ["file": (file as NSString).expandingTildeInPath]
      }
      guard let text = try part.string("text"), !text.isEmpty else {
        throw RPCError.invalidParams("parts[\(index)].text must be a non-empty string")
      }
      var result: [String: Any] = ["text": text]
      if let formatting = try part.objectArray("text_formatting", aliases: ["textFormatting"]) {
        result["textFormatting"] = formatting
      }
      return result
    }
  }

  static func hasFiles(_ parts: [[String: Any]]) -> Bool {
    parts.contains { $0["file"] != nil }
  }

  static func requireFileSupport(_ status: [String: Any]) throws {
    let selectors = status["selectors"] as? [String: Any]
    guard selectors?["sendMultipartFiles"] as? Bool == true else {
      throw RPCError.internalError(
        "running bridge does not support multipart files; restart Messages with the current imsg bridge"
      )
    }
  }

  static func stage(
    _ parts: [[String: Any]], using stageAttachment: (String) throws -> String
  ) throws -> [[String: Any]] {
    try parts.map { part in
      guard let file = part["file"] as? String else { return part }
      return ["file": try stageAttachment(file)]
    }
  }
}
