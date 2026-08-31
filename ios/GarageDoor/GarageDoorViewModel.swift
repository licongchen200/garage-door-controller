import AuthenticationServices
import Combine
import Foundation
import SwiftUI

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var appToken: String?
    @Published private(set) var appleUserID: String?

    private let keychain: KeychainStore
    private let tokenKey = "app-jwt"
    private let userKey = "apple-user-id"

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        appToken = try? keychain.read(tokenKey)
        appleUserID = try? keychain.read(userKey)
    }

    var isAuthenticated: Bool { appToken != nil }

    func store(token: String, appleUserID: String) throws {
        try keychain.save(token, for: tokenKey)
        try keychain.save(appleUserID, for: userKey)
        self.appToken = token
        self.appleUserID = appleUserID
    }

    func signOut() {
        keychain.delete(tokenKey)
        keychain.delete(userKey)
        appToken = nil
        appleUserID = nil
    }
}

@MainActor
final class GarageDoorViewModel: ObservableObject {
    @Published private(set) var doorState: DoorState = .unknown
    @Published private(set) var online = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    let auth: AuthStore
    private let api: APIClient
    // AuthStore is a nested ObservableObject: its own @Published changes (e.g.
    // signOut() clearing appToken) do NOT automatically propagate to this
    // view model's objectWillChange, so SwiftUI never re-renders ContentView
    // on sign-out without this forwarding subscription.
    private var authCancellable: AnyCancellable?

    init(api: APIClient = APIClient(), auth: AuthStore? = nil) {
        self.api = api
        let resolvedAuth = auth ?? AuthStore()
        self.auth = resolvedAuth
        authCancellable = resolvedAuth.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var displayedState: String {
        guard online else { return "Unreachable" }
        return doorState.title
    }

    var actionTitle: String { doorState == .open ? "Close" : "Open" }

    func completeSignIn(_ result: Result<ASAuthorization, Error>) async {
        do {
            guard case .success(let authorization) = result,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                throw APIError.server("Sign in with Apple did not return an identity token.")
            }
            let response = try await api.signInWithApple(
                identityToken: identityToken,
                userID: credential.user
            )
            try auth.store(token: response.accessToken, appleUserID: response.appleUserID)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        guard let token = auth.appToken else { return }
        do {
            let response = try await api.fetchDoorState(token: token)
            doorState = response.state
            online = response.online
            errorMessage = nil
        } catch {
            // Server reachability is distinct from an online ESP32. Keep the last
            // door value, but show it as unreachable until a fresh response arrives.
            online = false
            errorMessage = error.localizedDescription
        }
    }

    func pollWhileForegrounded() async {
        while !Task.isCancelled, auth.isAuthenticated {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func performAction() async {
        guard let token = auth.appToken, doorState == .open || doorState == .closed else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let command: DoorState = doorState == .open ? .closed : .open
            let response = try await api.sendCommand(command, token: token)
            guard response.result == "triggered" else {
                throw APIError.server("The door controller did not accept the command.")
            }
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
