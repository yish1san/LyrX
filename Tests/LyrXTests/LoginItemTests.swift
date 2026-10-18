import XCTest
@testable import LyrX

@MainActor
private final class TestLoginItemService: LoginItemService {
    var state: LoginItemState = .disabled
    var registrations = 0
    var unregistrations = 0
    var openedSettings = 0
    var approvalRequired = false
    var fails = false
    func register() throws {
        registrations += 1
        if fails { throw CocoaError(.featureUnsupported) }
        state = approvalRequired ? .requiresApproval : .enabled
    }
    func unregister() throws {
        unregistrations += 1
        if fails { throw CocoaError(.featureUnsupported) }
        state = .disabled
    }
    func openSettings() { openedSettings += 1 }
}

final class LoginItemTests: XCTestCase {
    @MainActor func testInitializationReadsStateWithoutRegistering() async {
        let service = TestLoginItemService()
        let settings = LoginItemSettings(service: service)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
    }
    @MainActor func testToggleRegistersAndUnregisters() async {
        let service = TestLoginItemService()
        let settings = LoginItemSettings(service: service)
        settings.setEnabled(true)
        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(service.registrations, 1)
        settings.setEnabled(false)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(service.unregistrations, 1)
    }
    @MainActor func testApprovalRequiredIsVisibleAndCanBeCancelled() async {
        let service = TestLoginItemService(); service.approvalRequired = true
        let settings = LoginItemSettings(service: service)
        settings.setEnabled(true)
        XCTAssertEqual(settings.state, .requiresApproval)
        XCTAssertTrue(settings.isEnabled)
        settings.openSettings()
        XCTAssertEqual(service.openedSettings, 1)
        settings.setEnabled(false)
        XCTAssertEqual(settings.state, .disabled)
    }
    @MainActor func testFailureDoesNotPretendToEnable() async {
        let service = TestLoginItemService(); service.fails = true
        let settings = LoginItemSettings(service: service)
        settings.setEnabled(true)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertNotNil(settings.errorMessage)
    }
    @MainActor func testRefreshReflectsSystemRevocationWithoutReregistering() async {
        let service = TestLoginItemService(); service.state = .enabled
        let settings = LoginItemSettings(service: service)
        XCTAssertTrue(settings.isEnabled)
        service.state = .disabled
        settings.refresh()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(service.registrations, 0)
    }
    @MainActor func testPreviewToggleDoesNotUseSystemService() async {
        let settings = LoginItemSettings(preview: true)
        settings.setEnabled(true)
        XCTAssertTrue(settings.isEnabled)
        settings.setEnabled(false)
        XCTAssertFalse(settings.isEnabled)
    }
}
