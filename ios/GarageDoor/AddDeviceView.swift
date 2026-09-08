import SwiftUI

struct AddDeviceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DeviceProvisioningViewModel

    init(api: APIClient, token: String?, onComplete: @escaping () -> Void = {}) {
        _model = StateObject(
            wrappedValue: DeviceProvisioningViewModel(api: api, token: token, onComplete: onComplete)
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GarageBackground()

                Form {
                    Section {
                        Label("Power on the new controller", systemImage: "power")
                            .font(.headline)
                        Text("Keep it close to your phone. The app will join its temporary setup network, send these Wi-Fi details, and return your phone to its normal network.")
                            .font(.body)
                            .foregroundStyle(GaragePalette.secondaryText)
                    }
                    .listRowBackground(GaragePalette.surface)

                    Section("Home Wi-Fi") {
                        TextField("Network name", text: $model.wifiSSID)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $model.wifiPassword)
                            .textContentType(.password)
                    }
                    .listRowBackground(GaragePalette.surface)

                    Section {
                        if let errorMessage = model.errorMessage {
                            ErrorMessage(message: errorMessage)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        } else if let message = model.message {
                            Label {
                                Text(message)
                            } icon: {
                                if model.isWorking {
                                    ProgressView()
                                        .tint(GaragePalette.amber)
                                } else {
                                    Image(systemName: model.completed ? "checkmark.circle.fill" : "info.circle.fill")
                                }
                            }
                            .foregroundStyle(model.completed ? GaragePalette.online : GaragePalette.primaryText)
                            .font(.subheadline)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }

                        Button {
                            if model.completed {
                                dismiss()
                            } else {
                                Task { await model.start() }
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text(model.completed ? "Done" : "Set Up Device")
                                    .font(.headline.weight(.bold))
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(GaragePrimaryButtonStyle(isEnabled: model.canStart || model.completed))
                        .disabled(!model.canStart && !model.completed)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
                .foregroundStyle(GaragePalette.primaryText)
            }
            .navigationTitle("Add a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isWorking)
                }
            }
        }
        .tint(GaragePalette.amber)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isWorking)
    }
}
