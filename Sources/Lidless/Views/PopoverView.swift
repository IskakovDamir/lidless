import LidlessCore
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isActive { ActiveSessionView() } else { SessionSetupView() }
            if let message = model.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if model.power.hasBattery {
                Divider()
                ClosedLidSection()
                Divider()
                PowerSection()
            }
            Divider()
            GeneralSection()
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Lidless").font(.headline)
            Spacer()
            Circle()
                .fill(model.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(model.isActive ? "Keeping awake" : "Idle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("v\(LidlessVersion.string)").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit Lidless") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.callout)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Session

private struct ActiveSessionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.remaining.map { DurationFormat.clock($0) } ?? "No limit")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if model.session?.ends != nil {
                    Button("+15 min") { model.extend() }
                        .controlSize(.large)
                }
                Button { model.stop() } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var subtitle: String {
        guard let session = model.session else { return "" }
        if let ends = session.ends {
            return "Until " + ends.formatted(date: .omitted, time: .shortened)
        }
        let running = model.now.timeIntervalSince(session.started)
        return "Running for " + DurationFormat.clock(running) + ", until you stop it"
    }
}

private struct SessionSetupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $model.mode) {
                ForEach(SessionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.mode {
            case .timer: timer
            case .until: until
            case .unlimited:
                Text("Stays awake until you press Stop.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Button { model.start() } label: {
                Text("Start").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            if let reason = model.lastEndReason {
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Choices.timerPresets, id: \.self) { minutes in
                    Button { model.timerMinutes = minutes } label: {
                        Text(DurationFormat.words(minutes: minutes)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PresetButtonStyle(selected: model.timerMinutes == minutes))
                }
            }
            Stepper(value: $model.timerMinutes, in: 5...(24 * 60), step: 5) {
                Text(DurationFormat.words(minutes: model.timerMinutes))
                    .monospacedDigit()
            }
        }
    }

    private var until: some View {
        VStack(alignment: .leading, spacing: 6) {
            DatePicker("Keep awake until", selection: $model.untilTime, displayedComponents: .hourAndMinute)
            if let end = model.plannedEnd(from: model.now) {
                let minutes = Int(end.timeIntervalSince(model.now) / 60)
                Text("That is in " + DurationFormat.words(minutes: max(1, minutes))
                     + (Calendar.current.isDateInToday(end) ? "" : ", tomorrow"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Quiet preset buttons: a hairline border and a small radius, filled when selected.
private struct PresetButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0 : 0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Settings sections

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
    }
}

private struct ClosedLidSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.closedLidEnabled) {
                SectionTitle(text: "Keep running with the lid closed")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if model.closedLidEnabled {
                Picker("While closed", selection: $model.closedLimitMinutes) {
                    ForEach(Choices.closedLimits, id: \.self) { minutes in
                        Text(minutes == 0 ? "Whole session" : DurationFormat.words(minutes: minutes)).tag(minutes)
                    }
                }
                .pickerStyle(.menu)

                LidStatusView()
            }
        }
    }
}

private struct LidStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let client = model.closedLid
        VStack(alignment: .leading, spacing: 6) {
            switch model.lidState {
            case .off:
                EmptyView()
            case .needsHelper:
                note("Needs a small helper that runs as root. One-time setup with your admin password.")
                installButton(title: "Install helper")
            case .helperStopped:
                note("The helper is installed but not running.")
                installButton(title: "Reinstall helper")
            case .idleArmed:
                note("Start a session, then close the lid once it says it is ready.")
            case .waiting:
                status(color: .orange, "Preparing, keep the lid open")
            case .ready:
                status(color: .green, "Ready to close the lid")
            case .stopped(let message):
                status(color: .red, message)
            }
            if client.updateAvailable && client.helper != .notInstalled {
                installButton(title: "Update helper")
            }
            if let error = client.installError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func status(color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func installButton(title: String) -> some View {
        Button(model.closedLid.installing ? "Waiting for password..." : title) {
            model.closedLid.install()
        }
        .disabled(model.closedLid.installing)
    }
}

private struct PowerSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Power")
                Spacer()
                Text(powerText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Toggle("Require charger", isOn: $model.requireCharger)
            Toggle("End on low battery", isOn: $model.endOnLowBattery)
            if model.endOnLowBattery {
                Stepper(value: $model.batteryCutoff, in: 10...80, step: 5) {
                    Text("Stop at \(model.batteryCutoff)%").monospacedDigit()
                }
            }
            if model.closedLidEnabled && !model.requireCharger {
                Text("With the lid closed on battery, Lidless always stops at \(ClosedLidRules.batteryFloor)% or your cutoff, whichever is higher.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var powerText: String {
        let percent = model.power.batteryPercent.map { "\($0)%" } ?? ""
        switch model.power.source {
        case .adapter: return "Charger, " + percent
        case .battery: return "Battery, " + percent
        case .unknown: return "Unknown"
        }
    }
}

private struct GeneralSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep the display on", isOn: $model.keepDisplayOn)
            Toggle("Show time left in the menu bar", isOn: $model.showTimeInMenuBar)
            Toggle("Open at login", isOn: Binding(
                get: { model.openAtLogin },
                set: { model.setOpenAtLogin($0) }))
            if model.closedLid.helper != .notInstalled {
                Button("Remove closed-lid helper") { model.closedLid.uninstall() }
                    .buttonStyle(.link)
                    .font(.callout)
                    .disabled(model.isActive || model.closedLid.installing)
            }
        }
        .toggleStyle(.checkbox)
    }
}
