import Foundation
import Combine
import NetworkExtension

enum DeviceSetupConstants {
    static let setupSSIDPrefix = "GarageDoor-Setup-"
    static let deviceURL = URL(string: "http://192.168.4.1")!
}

struct ProvisionedDevice: Equatable {
    let macAddress: String
}

enum DeviceProvisioningError: LocalizedError {
    case deviceNotFound
    case wifiRejected
    case unableToConfirm

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "Couldn't find the new device. Power it on and make sure its setup light is on, then try again."
        case .wifiRejected:
            return "The device was found, but it rejected those Wi-Fi credentials. Check the network name and password."
        case .unableToConfirm:
            return "The device was found, but the setup result could not be confirmed. Keep it powered on and try again."
        }
    }
}

enum DeviceProvisioningTransportError: Error {
    case deviceNotFound
    case credentialsRejected
    case requestFailed
}

protocol DeviceProvisioningTransport {
    func joinSetupNetwork() async throws
    func discoverDevice() async throws -> ProvisionedDevice
    func submitCredentials(ssid: String, password: String) async throws
    func waitForNormalNetwork() async -> Bool
}

struct DeviceProvisioningResult: Equatable {
    let device: ProvisionedDevice
    let normalNetworkRestored: Bool
}

struct DeviceProvisioningService {
    let transport: DeviceProvisioningTransport

    func provision(ssid: String, password: String) async throws -> DeviceProvisioningResult {
        do {
            try await transport.joinSetupNetwork()
            let device = try await transport.discoverDevice()
            try await transport.submitCredentials(ssid: ssid, password: password)
            let normalNetworkRestored = await transport.waitForNormalNetwork()
            return DeviceProvisioningResult(device: device, normalNetworkRestored: normalNetworkRestored)
        } catch DeviceProvisioningTransportError.deviceNotFound {
            throw DeviceProvisioningError.deviceNotFound
        } catch DeviceProvisioningTransportError.credentialsRejected {
            throw DeviceProvisioningError.wifiRejected
        } catch {
            throw DeviceProvisioningError.unableToConfirm
        }
    }
}

enum WiFiManagerResponseParser {
    static func deviceMAC(in data: Data) -> String? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"garage-device-mac"\s+content="([0-9A-Fa-f:-]{12,17})""#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let value = String(html[range]).replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard value.count == 12, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    static func credentialsWereRejected(statusCode: Int, body: Data) -> Bool {
        guard (200..<300).contains(statusCode) else { return true }
        guard let text = String(data: body, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("authentication failure")
            || text.contains("ap not found")
            || text.contains("could not connect")
    }
}

final class WiFiManagerTransport: DeviceProvisioningTransport {
    private let session: URLSession
    private let configurationManager: NEHotspotConfigurationManager

    init(
        session: URLSession = .shared,
        configurationManager: NEHotspotConfigurationManager = .shared
    ) {
        self.session = session
        self.configurationManager = configurationManager
    }

    func joinSetupNetwork() async throws {
        let configuration = NEHotspotConfiguration(ssidPrefix: DeviceSetupConstants.setupSSIDPrefix)
        configuration.joinOnce = true
        try await withCheckedThrowingContinuation { continuation in
            configurationManager.apply(configuration) { error in
                if let error {
                    // alreadyAssociated is the successful path when the phone is
                    // already on the device's setup network.
                    if (error as NSError).code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: DeviceProvisioningTransportError.deviceNotFound)
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func discoverDevice() async throws -> ProvisionedDevice {
        let (data, response) = try await request(path: "")
        guard (200..<300).contains(response.statusCode),
              let macAddress = WiFiManagerResponseParser.deviceMAC(in: data) else {
            throw DeviceProvisioningTransportError.deviceNotFound
        }
        return ProvisionedDevice(macAddress: macAddress)
    }

    func submitCredentials(ssid: String, password: String) async throws {
        var postRequest = URLRequest(url: DeviceSetupConstants.deviceURL.appendingPathComponent("wifisave"))
        postRequest.httpMethod = "POST"
        postRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        postRequest.httpBody = "s=\(formEncoded(ssid))&p=\(formEncoded(password))".data(using: .utf8)

        do {
            let (data, response) = try await data(for: postRequest)
            if WiFiManagerResponseParser.credentialsWereRejected(statusCode: response.statusCode, body: data) {
                throw DeviceProvisioningTransportError.credentialsRejected
            }
        } catch let error as DeviceProvisioningTransportError {
            throw error
        } catch {
            throw DeviceProvisioningTransportError.requestFailed
        }

        // WiFiManager sends its success page before it attempts the station
        // connection. A successful attempt closes the temporary AP; a failed
        // attempt leaves it up and exposes its status text.
        for _ in 0..<15 {
            try? await Task.sleep(for: .seconds(1))
            do {
                let (data, response) = try await request(path: "")
                if WiFiManagerResponseParser.credentialsWereRejected(statusCode: response.statusCode, body: data) {
                    throw DeviceProvisioningTransportError.credentialsRejected
                }
            } catch let error as DeviceProvisioningTransportError {
                if case .credentialsRejected = error { throw error }
                // The AP disappearing is WiFiManager's success signal.
                return
            } catch {
                // The AP disappearing is WiFiManager's success signal.
                return
            }
        }
        throw DeviceProvisioningTransportError.credentialsRejected
    }

    func waitForNormalNetwork() async -> Bool {
        for _ in 0..<12 {
            let currentSSID = await currentSSID()
            // A nil result can mean that iOS has not granted Wi-Fi visibility yet,
            // so it is not proof that the phone returned to its normal network.
            if let currentSSID, !currentSSID.hasPrefix(DeviceSetupConstants.setupSSIDPrefix) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func request(path: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: DeviceSetupConstants.deviceURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await data(for: request)
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DeviceProvisioningTransportError.requestFailed
        }
        return (data, httpResponse)
    }

    private func currentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    private func formEncoded(_ value: String) -> String {
        value.utf8.reduce(into: String()) { result, byte in
            if byte == 0x20 {
                result.append("+")
            } else if (0x30...0x39).contains(byte)
                        || (0x41...0x5A).contains(byte)
                        || (0x61...0x7A).contains(byte)
                        || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append(String(format: "%%%02X", byte))
            }
        }
    }
}

@MainActor
final class DeviceProvisioningViewModel: ObservableObject {
    @Published var wifiSSID = ""
    @Published var wifiPassword = ""
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var completed = false

    private let service: DeviceProvisioningService
    private let api: APIClient
    private let token: String?
    private let onComplete: () -> Void

    init(
        api: APIClient,
        token: String?,
        service: DeviceProvisioningService = DeviceProvisioningService(transport: WiFiManagerTransport()),
        onComplete: @escaping () -> Void = {}
    ) {
        self.api = api
        self.token = token
        self.service = service
        self.onComplete = onComplete
    }

    var canStart: Bool {
        !wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    func start() async {
        guard canStart else { return }
        isWorking = true
        message = "Joining the device’s setup network…"
        errorMessage = nil
        defer { isWorking = false }

        do {
            let result = try await service.provision(ssid: wifiSSID, password: wifiPassword)
            guard let token else {
                throw APIError.server("Sign in is required before adding a device.")
            }
            message = "Registering device…"
            _ = try await api.registerDevice(macAddress: result.device.macAddress, token: token)
            completed = true
            message = result.normalNetworkRestored
                ? "Device added. Your phone is back on its normal network."
                : "Device added. iOS is still leaving the temporary setup network."
            onComplete()
        } catch let error as DeviceProvisioningError {
            errorMessage = error.localizedDescription
            message = nil
        } catch {
            errorMessage = "Wi-Fi was configured, but the device could not be registered: \(error.localizedDescription)"
            message = nil
        }
    }
}
