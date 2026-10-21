import Foundation
import IMsgCore

extension RPCServer {
  func handleSendMultipart(params: [String: Any], id: Any?) async throws {
    let supportedKeys = RPCParameterKeys.combining(
      RPCParameterKeys.chatTarget,
      ["parts", "effect_id", "effectId", "effect", "subject"]
    )
    let params = try RPCParameters(
      params, method: "send.multipart", supportedKeys: supportedKeys)
    guard let rawParts = try params.objectArray("parts") else {
      throw RPCError.invalidParams("parts is required")
    }
    let parts = try MultipartParts.validate(rawParts)

    let effect = try params.string("effect_id", aliases: ["effectId", "effect"])
    let subject = try params.string("subject")
    let chatGUID = try await resolveChatGUIDParam(params)
    var bridgeParams: [String: Any] = ["chatGuid": chatGUID, "parts": parts]
    if let effect, !effect.isEmpty {
      bridgeParams["effectId"] = ExpressiveSendEffect.expand(effect)
    }
    if let subject, !subject.isEmpty {
      bridgeParams["subject"] = subject
    }

    let verification = try await bridgeSendVerificationBaseline()
    if MultipartParts.hasFiles(parts) {
      let status = try await invokeBridge(action: .status, params: [:])
      try MultipartParts.requireFileSupport(status)
      do {
        bridgeParams["parts"] = try MultipartParts.stage(parts, using: stageAttachment)
      } catch {
        throw DeliveryFailure(
          disposition: .notStarted, transport: .bridgeV2,
          operation: BridgeAction.sendMultipart.rawValue,
          detail: "The attachments could not be staged before bridge dispatch.")
      }
    }
    let data = try await invokeBridge(action: .sendMultipart, params: bridgeParams)
    var result = try await verifiedBridgeSendResponse(
      data,
      params: params,
      chatGUID: chatGUID,
      action: .sendMultipart,
      database: verification.database,
      baselineRowID: verification.rowID
    )
    result["ok"] = true
    result["parts_count"] = parts.count
    respond(id: id, result: result)
  }
}
