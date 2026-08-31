import AuthenticationServices
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var auth: AuthStore
    @StateObject private var model: GarageDoorViewModel

    init() {
        let auth = AuthStore()
        _auth = StateObject(wrappedValue: auth)
        _model = StateObject(wrappedValue: GarageDoorViewModel(auth: auth))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GarageBackground()

                Group {
                    if auth.isAuthenticated {
                        doorView
                    } else {
                        signInView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(GaragePalette.amber)
        .preferredColorScheme(.dark)
        .task(id: "\(scenePhase == .active)-\(auth.isAuthenticated)") {
            guard scenePhase == .active, auth.isAuthenticated else { return }
            await model.pollWhileForegrounded()
        }
    }

    private var signInView: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 48)

                BrandMark(size: 92)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text("Garage Door")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(GaragePalette.primaryText)

                    Text("Your home, at a glance.")
                        .font(.system(.title3, design: .rounded).weight(.medium))
                        .foregroundStyle(GaragePalette.amber)

                    Text("Check your door and control it securely\nfrom wherever you are.")
                        .font(.body)
                        .foregroundStyle(GaragePalette.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 24)

                HStack(spacing: 10) {
                    WelcomeFeature(systemName: "lock.fill", text: "Secure")
                    WelcomeFeature(systemName: "bolt.fill", text: "Instant")
                    WelcomeFeature(systemName: "house.fill", text: "At home")
                }
                .padding(.top, 32)

                VStack(spacing: 16) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        Task { await model.completeSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                    if let errorMessage = model.errorMessage {
                        ErrorMessage(message: errorMessage)
                    }
                }
                .padding(.top, 40)

                Label("Sign in with Apple keeps your access private", systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(GaragePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                    .accessibilityLabel("Secure access with Sign in with Apple")

                Spacer(minLength: 40)
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var doorView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    BrandMark(size: 42)
                        .accessibilityHidden(true)

                    Text("Garage Door")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(GaragePalette.primaryText)

                    Spacer(minLength: 12)

                    ConnectionPill(isOnline: model.online)
                }
                .padding(.top, 18)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Home overview")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(GaragePalette.primaryText)
                    Text("Monitor and control your garage door.")
                        .font(.body)
                        .foregroundStyle(GaragePalette.secondaryText)
                }
                .padding(.top, 38)

                StateCard(
                    state: model.displayedState,
                    icon: model.online ? doorIcon : "wifi.slash",
                    color: stateColor,
                    description: stateDescription
                )
                .padding(.top, 28)

                Button {
                    Task { await model.performAction() }
                } label: {
                    HStack(spacing: 10) {
                        if model.isBusy {
                            ProgressView()
                                .tint(GaragePalette.navy)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: model.doorState == .open ? "arrow.down.to.line" : "arrow.up.to.line")
                                .font(.headline.weight(.bold))
                                .accessibilityHidden(true)
                        }
                        Text(model.isBusy ? "Working…" : model.actionTitle)
                    }
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
                .buttonStyle(GaragePrimaryButtonStyle(isEnabled: actionEnabled))
                .disabled(!actionEnabled)
                .accessibilityLabel(model.isBusy ? "Updating garage door" : "\(model.actionTitle) garage door")
                .accessibilityHint(actionEnabled ? "Activates the garage door." : "Unavailable while the controller is unreachable.")
                .padding(.top, 22)

                if let errorMessage = model.errorMessage {
                    ErrorMessage(message: errorMessage)
                        .padding(.top, 18)
                }

                Button {
                    auth.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GaragePalette.secondaryText)
                .contentShape(Rectangle())
                .padding(.top, 18)
                .accessibilityHint("Signs out of this garage door account.")

                Text("Only activate the door when it is safe to do so.")
                    .font(.footnote)
                    .foregroundStyle(GaragePalette.secondaryText.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 26)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var actionEnabled: Bool {
        model.online && !model.isBusy && (model.doorState == .open || model.doorState == .closed)
    }

    private var stateColor: Color {
        guard model.online else { return GaragePalette.offline }
        return model.doorState == .open ? GaragePalette.amber : GaragePalette.closed
    }

    private var stateDescription: String {
        guard model.online else { return "Controller unreachable" }
        switch model.doorState {
        case .open, .closed: return "Ready to operate"
        case .unknown: return "State is being determined"
        }
    }

    private var doorIcon: String {
        model.doorState == .open ? "door.left.hand.open" : "door.left.hand.closed"
    }
}

private struct GarageBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [GaragePalette.navy, GaragePalette.indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(GaragePalette.amber.opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 30)
                .offset(x: 150, y: -360)

            Circle()
                .fill(Color.cyan.opacity(0.06))
                .frame(width: 360, height: 360)
                .blur(radius: 50)
                .offset(x: -190, y: 390)
        }
        .ignoresSafeArea()
    }
}

private struct BrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [GaragePalette.amber, GaragePalette.orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "door.left.hand.open")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(GaragePalette.navy)
        }
        .frame(width: size, height: size)
        .shadow(color: GaragePalette.amber.opacity(0.22), radius: 18, y: 8)
    }
}

private struct WelcomeFeature: View {
    let systemName: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GaragePalette.amber)
                .frame(width: 34, height: 34)
                .background(GaragePalette.amber.opacity(0.12), in: Circle())
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(GaragePalette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionPill: View {
    let isOnline: Bool

    var body: some View {
        Label(isOnline ? "Online" : "Offline", systemImage: isOnline ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(isOnline ? GaragePalette.online : GaragePalette.offline)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background((isOnline ? GaragePalette.online : GaragePalette.offline).opacity(0.13), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isOnline ? "Controller online" : "Controller offline")
    }
}

private struct StateCard: View {
    let state: String
    let icon: String
    let color: Color
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("DOOR STATUS")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(GaragePalette.secondaryText)

            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 94, height: 94)
                    .background(color.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    Text(state)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(GaragePalette.primaryText)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(GaragePalette.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GaragePalette.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Garage door state")
        .accessibilityValue("\(state). \(description)")
    }
}

private struct ErrorMessage: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.subheadline)
        .foregroundStyle(GaragePalette.error)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(GaragePalette.error.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GaragePalette.error.opacity(0.28), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

private struct GaragePrimaryButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? GaragePalette.navy : GaragePalette.secondaryText)
            .background(
                isEnabled
                    ? AnyShapeStyle(LinearGradient(colors: [GaragePalette.amber, GaragePalette.orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(GaragePalette.surface)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isEnabled ? GaragePalette.amber.opacity(0.5) : GaragePalette.secondaryText.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: isEnabled ? GaragePalette.amber.opacity(0.2) : .clear, radius: 14, y: 7)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private enum GaragePalette {
    static let navy = Color(red: 0.035, green: 0.055, blue: 0.15)
    static let indigo = Color(red: 0.09, green: 0.10, blue: 0.27)
    static let surface = Color.white.opacity(0.10)
    static let amber = Color(red: 1.0, green: 0.60, blue: 0.18)
    static let orange = Color(red: 1.0, green: 0.36, blue: 0.10)
    static let closed = Color(red: 0.35, green: 0.78, blue: 0.95)
    static let online = Color(red: 0.42, green: 0.86, blue: 0.68)
    static let offline = Color(red: 1.0, green: 0.48, blue: 0.43)
    static let error = Color(red: 1.0, green: 0.53, blue: 0.48)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
}
