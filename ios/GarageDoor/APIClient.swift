import Foundation

struct AppleAuthResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let appleUserID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case appleUserID = "apple_user_id"
    }
}

struct DoorStateResponse: Decodable {
    let state: DoorState
    let online: Bool
    let timestamp: String?

    enum CodingKeys: String, CodingKey { case state, online, ts }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(DoorState.self, forKey: .state)
        online = try container.decode(Bool.self, forKey: .online)
        if let string = try? container.decodeIfPresent(String.self, forKey: .ts) {
            timestamp = string
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .ts) {
            timestamp = String(number)
        } else {
            timestamp = nil
        }
    }
}

struct DoorCommandResponse: Decodable {
    let result: String
    let id: String
}

enum DoorState: String, Codable {
    case open
    case closed
    case unknown

    var title: String { rawValue.capitalized }
}

enum APIError: LocalizedError {
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .server(let message): return message
        }
    }
}

struct APIClient {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = APIClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    static var defaultBaseURL: URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
           let url = URL(string: value) {
            return url
        }
        // Replace APIBaseURL in the app's generated Info.plist before installing.
        return URL(string: "https://garage.example.invalid")!
    }

    func signInWithApple(identityToken: String, userID: String) async throws -> AppleAuthResponse {
        let body = ["identity_token": identityToken, "apple_user_id": userID]
        return try await send(path: "/auth/apple", method: "POST", body: body, token: nil)
    }

    func fetchDoorState(token: String) async throws -> DoorStateResponse {
        try await send(path: "/door/state", method: "GET", body: Optional<String>.none, token: token)
    }

    func sendCommand(_ command: DoorState, token: String) async throws -> DoorCommandResponse {
        let path = command == .open ? "/door/open" : "/door/close"
        return try await send(path: path, method: "POST", body: Optional<String>.none, token: token)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?,
        token: String?
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let detail = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw APIError.server(detail.detail)
            }
            throw APIError.server("The server returned HTTP \(http.statusCode).")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

private struct ServerError: Decodable { let detail: String }
