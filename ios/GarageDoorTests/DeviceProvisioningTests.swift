import XCTest
@testable import GarageDoor

final class DeviceProvisioningTests: XCTestCase {
    func testDeviceFoundAndConfigured() async throws {
        let transport = FakeProvisioningTransport()
        let service = DeviceProvisioningService(transport: transport)

        let result = try await service.provision(ssid: "Home Wi-Fi", password: "secret")

        XCTAssertEqual(result.device.macAddress, "aabbccddeeff")
        XCTAssertTrue(result.normalNetworkRestored)
        XCTAssertEqual(transport.submittedSSID, "Home Wi-Fi")
        XCTAssertEqual(transport.submittedPassword, "secret")
    }

    func testJoinFailureIsReportedAsDeviceNotFound() async {
        let transport = FakeProvisioningTransport(joinError: .deviceNotFound)
        let service = DeviceProvisioningService(transport: transport)

        do {
            _ = try await service.provision(ssid: "Home Wi-Fi", password: "secret")
            XCTFail("expected device-not-found error")
        } catch let error as DeviceProvisioningError {
            XCTAssertEqual(error.localizedDescription, DeviceProvisioningError.deviceNotFound.localizedDescription)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testCredentialRejectionIsReportedSeparately() async {
        let transport = FakeProvisioningTransport(submitError: .credentialsRejected)
        let service = DeviceProvisioningService(transport: transport)

        do {
            _ = try await service.provision(ssid: "Home Wi-Fi", password: "wrong")
            XCTFail("expected credential-rejected error")
        } catch let error as DeviceProvisioningError {
            XCTAssertEqual(error.localizedDescription, DeviceProvisioningError.wifiRejected.localizedDescription)
            XCTAssertNotEqual(error.localizedDescription, DeviceProvisioningError.deviceNotFound.localizedDescription)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWiFiManagerResponsesExposeDeviceMACAndRejectStatus() {
        let html = #"<meta name="garage-device-mac" content="AA:BB:CC:DD:EE:FF">"#
        XCTAssertEqual(
            WiFiManagerResponseParser.deviceMAC(in: Data(html.utf8)),
            "aabbccddeeff"
        )
        XCTAssertTrue(
            WiFiManagerResponseParser.credentialsWereRejected(
                statusCode: 200,
                body: Data("<div>Authentication failure</div>".utf8)
            )
        )
        XCTAssertFalse(
            WiFiManagerResponseParser.credentialsWereRejected(
                statusCode: 200,
                body: Data("Credentials Saved".utf8)
            )
        )
    }
}

private final class FakeProvisioningTransport: DeviceProvisioningTransport {
    let joinError: DeviceProvisioningTransportError?
    let submitError: DeviceProvisioningTransportError?
    var submittedSSID: String?
    var submittedPassword: String?

    init(
        joinError: DeviceProvisioningTransportError? = nil,
        submitError: DeviceProvisioningTransportError? = nil
    ) {
        self.joinError = joinError
        self.submitError = submitError
    }

    func joinSetupNetwork() async throws {
        if let joinError { throw joinError }
    }

    func discoverDevice() async throws -> ProvisionedDevice {
        ProvisionedDevice(macAddress: "aabbccddeeff")
    }

    func submitCredentials(ssid: String, password: String) async throws {
        submittedSSID = ssid
        submittedPassword = password
        if let submitError { throw submitError }
    }

    func waitForNormalNetwork() async -> Bool { true }
}
