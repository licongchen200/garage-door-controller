import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = GarageDoorViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if model.auth.isAuthenticated {
                    doorView
                } else {
                    signInView
                }
            }
            .padding()
            .navigationTitle("Garage Door")
        }
        .task(id: "\(scenePhase == .active)-\(model.auth.isAuthenticated)") {
            guard scenePhase == .active, model.auth.isAuthenticated else { return }
            await model.pollWhileForegrounded()
        }
    }

    private var signInView: some View {
        VStack(spacing: 24) {
            Image(systemName: "house.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Sign in to control your garage door")
                .font(.title3)
                .multilineTextAlignment(.center)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email, .fullName]
            } onCompletion: { result in
                Task { await model.completeSignIn(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: 420)
    }

    private var doorView: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: model.online ? doorIcon : "wifi.slash")
                    .font(.system(size: 72))
                    .foregroundStyle(model.online ? Color.accentColor : Color.secondary)
                Text(model.displayedState)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Garage door: \(model.displayedState)")

            Button {
                Task { await model.performAction() }
            } label: {
                Text(model.actionTitle)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || !model.online || (model.doorState != .open && model.doorState != .closed))

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Sign Out", role: .destructive) { model.auth.signOut() }
            Spacer()
        }
        .frame(maxWidth: 420)
    }

    private var doorIcon: String {
        model.doorState == .open ? "door.left.hand.open" : "door.left.hand.closed"
    }
}
