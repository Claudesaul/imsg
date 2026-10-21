import Commander
import Foundation
import Testing

@testable import IMsgCore
@testable import imsg

@Test
func multipartValidatesAllPartsBeforeStaging() throws {
  let invalid: [[[String: Any]]] = [
    [], [["file": ""]], [["file": 1]], [["file": NSNull()]],
    [["text": "caption", "file": "/one.jpg"]],
    [["file": "/one.jpg", "textFormatting": []]],
    [["text": "ok"], ["mention": "+123"]],
    Array(repeating: ["text": "x"], count: 21),
  ]
  for parts in invalid {
    #expect(throws: (any Error).self) { try MultipartParts.validate(parts) }
  }
  let normalized = try MultipartParts.validate([
    ["text": "caption", "text_formatting": [["start": 0, "length": 1, "styles": ["bold"]]]],
    ["file": "~/one.jpg"],
  ])
  #expect(normalized[0]["textFormatting"] != nil)
  #expect(normalized[1]["file"] as? String == NSHomeDirectory() + "/one.jpg")
}

@Test
func multipartCLIStagesFourFilesAndDispatchesOnce() async throws {
  let raw = (1...4).map { ["file": "/photo-\($0).jpg"] }
  let json = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
  let values = ParsedValues(
    positional: [], options: ["chat": ["iMessage;+;test"], "parts": [json]], flags: [])
  var actions: [BridgeAction] = []
  var staged: [String] = []
  var captured: [[String: Any]] = []
  _ = try await StdoutCapture.capture {
    try await SendMultipartCommand.run(
      values: values, runtime: RuntimeOptions(parsedValues: values),
      invokeBridge: { action, params in
        actions.append(action)
        if action == .status { return ["selectors": ["sendMultipartFiles": true]] }
        captured = params["parts"] as? [[String: Any]] ?? []
        return ["messageGuid": "four-guid", "parts_count": 4]
      },
      stageAttachment: { path in
        staged.append(path)
        return "/staged" + path
      }
    )
  }
  #expect(actions == [.status, .sendMultipart])
  #expect(staged == raw.compactMap { $0["file"] })
  #expect(captured.compactMap { $0["file"] as? String } == staged.map { "/staged" + $0 })
}

@Test
func multipartCLIRejectsOldBridgeAndStagingFailureWithoutSending() async throws {
  for oldBridge in [true, false] {
    let values = ParsedValues(
      positional: [],
      options: [
        "chat": ["iMessage;+;test"], "parts": [#"[{"file":"/one.jpg"},{"file":"/two.jpg"}]"#],
      ], flags: [])
    var actions: [BridgeAction] = []
    var stageCalls = 0
    do {
      try await SendMultipartCommand.run(
        values: values, runtime: RuntimeOptions(parsedValues: values),
        invokeBridge: { action, _ in
          actions.append(action)
          return ["selectors": ["sendMultipartFiles": !oldBridge]]
        },
        stageAttachment: { path in
          stageCalls += 1
          if stageCalls == 2 { throw CocoaError(.fileReadNoSuchFile) }
          return path
        }
      )
      Issue.record("Expected failure")
    } catch {}
    #expect(actions == [.status])
    #expect(stageCalls == (oldBridge ? 0 : 2))
  }
}
