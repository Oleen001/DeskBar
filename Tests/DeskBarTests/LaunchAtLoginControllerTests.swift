import ServiceManagement
import XCTest
@testable import DeskBar

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testRunningOutsideApplicationBundleIsUnavailable() {
        let service = ServiceDouble(status: .notRegistered)
        let controller = LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/tmp/DeskBar"),
            bundleIdentifier: "com.example.DeskBar",
            service: service
        )

        guard case .unavailable = controller.state else {
            return XCTFail("Expected an unavailable state outside a .app bundle")
        }
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testControllerDoesNotRegisterDuringInitialization() {
        let service = ServiceDouble(status: .notRegistered)
        let controller = makeController(service: service)

        XCTAssertEqual(controller.state, .disabled)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testEnablingAndDisablingUpdatesState() async {
        let service = ServiceDouble(status: .notRegistered)
        let controller = makeController(service: service)

        await controller.setEnabled(true)
        XCTAssertEqual(controller.state, .enabled)
        XCTAssertEqual(service.registerCallCount, 1)

        await controller.setEnabled(false)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testRequiresApprovalDoesNotAttemptRegistration() async {
        let service = ServiceDouble(status: .requiresApproval)
        let controller = makeController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testRegistrationErrorIsExposed() async {
        let service = ServiceDouble(status: .notRegistered)
        service.registerError = TestError.registrationFailed
        let controller = makeController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.state, .disabled)
        XCTAssertEqual(controller.lastError, TestError.registrationFailed.localizedDescription)
        XCTAssertFalse(controller.isUpdating)
    }

    private func makeController(service: ServiceDouble) -> LaunchAtLoginController {
        LaunchAtLoginController(
            bundleURL: URL(fileURLWithPath: "/Applications/DeskBar.app"),
            bundleIdentifier: "com.example.DeskBar",
            service: service
        )
    }
}

@MainActor
private final class ServiceDouble: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() async throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private enum TestError: LocalizedError {
    case registrationFailed

    var errorDescription: String? {
        "Registration failed"
    }
}
