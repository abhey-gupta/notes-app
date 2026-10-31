import DesignSystem
import SwiftUI
import Sync

/// Settings › Sync › Devices (#225 mock 01), shown in place of the settings column: every device using the folder, this one
/// first ("This iPad", "Now"), the others by when they were last seen.
struct DevicesView: View {
    let sync: SyncModel

    @State private var devices: [DeviceRecord] = []
    @State private var me: String?

    var body: some View {
        Form {
            Section {
                ForEach(devices) { device in
                    row(device, isThis: device.id == me)
                }
            } header: {
                Text("Using this folder")
            } footer: {
                Text(
                    """
                    Every device that syncs with \(sync.folderName ?? "this folder"). A device unseen for 90 days drops off the \
                    list; its notebooks stay.
                    """
                )
            }
        }
        .task {
            me = sync.engine?.device.id
            devices = await sync.devices()
        }
    }

    private func row(_ device: DeviceRecord, isThis: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: Self.symbol(for: device.model))
                .scaledFont(size: 20)
                .foregroundStyle(Tokens.Colors.textSecondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .scaledFont(size: 15.5, weight: .medium)
                    .foregroundStyle(Tokens.Colors.textPrimary)
                    .lineLimit(1)
                if isThis {
                    Text("This \(device.model)")
                        .scaledFont(size: 12.5)
                        .foregroundStyle(Tokens.Colors.textSecondary)
                }
            }
            Spacer(minLength: Tokens.Spacing.s)
            Text(isThis ? "Now" : SyncSettingsSection.ago(device.lastSeen, now: Date()))
                .scaledFont(size: 13)
                .foregroundStyle(Tokens.Colors.textSecondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("device-\(device.name)")
    }

    /// `ipad`, `iphone`, `laptopcomputer` by model name.
    private static func symbol(for model: String) -> String {
        if model.hasPrefix("iPhone") {
            return "iphone"
        }
        if model.hasPrefix("Mac") {
            return "laptopcomputer"
        }
        return "ipad"
    }
}
