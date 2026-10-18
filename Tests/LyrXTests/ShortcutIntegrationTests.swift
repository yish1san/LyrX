import AppKit
import Carbon
import XCTest
@testable import LyrX

final class ShortcutIntegrationTests: XCTestCase {
    /// 原生事件集成检查，需要 WindowServer；默认测试不占用用户快捷键。
    @MainActor func testNativeHotKeyDispatchConflictRepeatAndCleanup() async throws {
        guard ProcessInfo.processInfo.environment["LYRX_RUN_SHORTCUT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LYRX_RUN_SHORTCUT_INTEGRATION=1 to test native hot-key registration.")
        }
        _ = NSApplication.shared
        let first = GlobalShortcut(), second = GlobalShortcut()
        defer { first.stop(); second.stop() }
        var firstCount = 0, secondCount = 0
        XCTAssertTrue(first.start { firstCount += 1 })
        XCTAssertFalse(second.start { secondCount += 1 }, "Conflicting registration must fail.")
        func send(_ kind: UInt32, signature: OSType = 0x4C795258, id: UInt32 = 1) throws {
            var createdEvent: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(), 0, &createdEvent), noErr)
            let event = try XCTUnwrap(createdEvent)
            defer { ReleaseEvent(event) }
            var key = EventHotKeyID(signature: signature, id: id)
            XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject),
                                             EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key), noErr)
            _ = SendEventToEventTarget(event, GetApplicationEventTarget())
        }
        try send(UInt32(kEventHotKeyPressed))
        try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(firstCount, 1, "Holding a key must not repeatedly toggle the overlay.")
        try send(UInt32(kEventHotKeyReleased))
        try send(UInt32(kEventHotKeyPressed), signature: 0, id: 2)
        XCTAssertEqual(firstCount, 1, "Unrelated hot keys must not run this action.")
        try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(firstCount, 2)
        first.stop()
        XCTAssertTrue(second.start { secondCount += 1 }, "Disabling must release the hot key.")
        try send(UInt32(kEventHotKeyPressed))
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(firstCount, 2, "The removed handler must not receive later events.")
    }
}
