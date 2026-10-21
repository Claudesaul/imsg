import Commander
import Foundation
import IMsgCore

enum SendMultipartCommand {
  static let spec = CommandSpec(
    name: "send-multipart",
    abstract: "Send a multi-part message",
    discussion: """
      Pass --parts as a JSON array (e.g., '[{"text":"hi"},{"text":"there"}]')
      or via --parts-file pointing at a .json file. Each of the 1–20 parts
      contains either text (with optional textFormatting) or a file path,
      e.g. [{"file":"/absolute/one.jpg"},{"file":"/absolute/two.jpg"}].
      All parts are sent in one message; photos appear as a grouped collection.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "chat", names: [.long("chat")], help: "chat guid"),
          .make(label: "parts", names: [.long("parts")], help: "JSON array of parts"),
          .make(
            label: "partsFile", names: [.long("parts-file")],
            help: "path to JSON file containing parts array"),
          .make(label: "effect", names: [.long("effect")], help: "expressive send id"),
          .make(label: "subject", names: [.long("subject")], help: "subject line"),
        ]
      )
    ),
    usageExamples: [
      "imsg send-multipart --chat 'iMessage;+;chat0000' --parts '[{\"text\":\"hi\"},{\"text\":\"world\"}]'"
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues, runtime: RuntimeOptions,
    invokeBridge: @escaping (BridgeAction, [String: Any]) async throws -> [String: Any] = {
      action, params in
      try await IMsgBridgeClient.shared.invoke(action: action, params: params)
    },
    stageAttachment: @escaping (String) throws -> String = MessageSender
      .stageAttachmentForMessagesApp
  ) async throws {
    guard let chat = values.option("chat"), !chat.isEmpty else {
      throw ParsedValuesError.missingOption("chat")
    }
    let partsRaw: String
    if let inline = values.option("parts"), !inline.isEmpty {
      partsRaw = inline
    } else if let path = values.option("partsFile"), !path.isEmpty {
      partsRaw = try String(contentsOfFile: path, encoding: .utf8)
    } else {
      throw ParsedValuesError.missingOption("parts")
    }
    guard
      let data = partsRaw.data(using: .utf8),
      let parts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      throw ParsedValuesError.invalidOption("parts")
    }
    let validated = try MultipartParts.validate(parts)
    var params: [String: Any] = ["chatGuid": chat, "parts": validated]
    if let effect = values.option("effect"), !effect.isEmpty {
      params["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject = values.option("subject"), !subject.isEmpty { params["subject"] = subject }

    if MultipartParts.hasFiles(validated) {
      let status = try await invokeBridge(.status, [:])
      try MultipartParts.requireFileSupport(status)
      params["parts"] = try MultipartParts.stage(validated, using: stageAttachment)
    }
    _ = try await BridgeOutput.invokeAndEmit(
      action: .sendMultipart, params: params, runtime: runtime, invokeBridge: invokeBridge
    ) { data in
      let guid = (data["messageGuid"] as? String) ?? ""
      let count = (data["parts_count"] as? Int) ?? 0
      return "send-multipart: \(count) parts queued (guid=\(guid))"
    }
  }
}

// MARK: - react (BB-style; complements existing AS-backed `react`)
