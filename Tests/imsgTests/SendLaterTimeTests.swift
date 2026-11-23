import Foundation
import Testing

@testable import imsg

@Test
func sendLaterParsesLocalAndRelativeTimes() {
  let zone = TimeZone(identifier: "America/New_York")!
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let local = SendLaterTime.parse("2026-11-24 09:30", now: now, timeZone: zone)
  #expect(local == ISO8601DateFormatter().date(from: "2026-11-24T14:30:00Z"))
  #expect(SendLaterTime.parse("+30m", now: now) == now.addingTimeInterval(1800))
  #expect(SendLaterTime.parse("+2h", now: now) == now.addingTimeInterval(7200))
  #expect(
    SendLaterTime.parse("2026-11-24T09:30:00-05:00", now: now)
      == ISO8601DateFormatter().date(from: "2026-11-24T14:30:00Z"))
  #expect(SendLaterTime.parse("+5x", now: now) == nil)
  #expect(SendLaterTime.parse("tomorrow", now: now) == nil)
}
