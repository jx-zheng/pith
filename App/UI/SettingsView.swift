import AppKit
import ServiceManagement
import SwiftUI
import PithCore

struct SettingsView: View {
    @AppStorage(Favourites.key(.convert)) private var favConvert = ""
    @AppStorage(Favourites.key(.tools)) private var favTools = ""
    @AppStorage(Favourites.key(.actions)) private var favActions = ""
    @AppStorage(AccentTheme.defaultsKey) private var accentRaw = AccentTheme.tangerine.rawValue
    @AppStorage(MenuBarPreference.key) private var showMenuBarIcon = true
    @ObservedObject var model: AppModel
    @State private var loginStatus = ""

    /// Every slider row shares these, so the tracks start and end at the same x.
    private static let sliderWidth: CGFloat = 220
    private static let valueWidth: CGFloat = 72

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Accent colour") {
                    HStack(spacing: 10) {
                        ForEach(AccentTheme.allCases) { theme in
                            Circle()
                                .fill(theme.highlight)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(accentRaw == theme.rawValue ? 0.9 : 0), lineWidth: 2).padding(-3))
                                .help(theme.title)
                                .onTapGesture { accentRaw = theme.rawValue }
                        }
                        Picker("Accent colour", selection: $accentRaw) {
                            ForEach(AccentTheme.allCases) { theme in
                                Text(theme.title).tag(theme.rawValue)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            Section("Wheels") {
                LabeledContent("Hotkey") {
                    Text("Shift")
                        .foregroundStyle(.secondary)
                }
                caption("Tap Shift while dragging a file, or click a file in Finder and then tap Shift. Each tap cycles Convert, then Tools, then Actions, then back to Convert. Hold longer than \(Int(model.settings.bindings.tapMaxDuration * 1000)) ms and it won't register. Escape dismisses the wheel.")
            }
            Section("Favourites") {
                favouritePicker("Convert", kind: .convert, selection: $favConvert)
                favouritePicker("Tools", kind: .tools, selection: $favTools)
                favouritePicker("Actions", kind: .actions, selection: $favActions)
                caption("A favourite is stored for each wheel. Shift cycles between wheels, so a second tap moves to the next wheel instead of running the favourite. Undo the last conversion or replace with ⌃⌥⌘Z, or with plain ⌘Z in Finder within 5 seconds of it finishing.")
            }
            Section("Output") {
                Picker("Location", selection: locationBinding) {
                    Text("Next to the source").tag(0)
                    Text("Fixed folder").tag(1)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                if case let .directory(path) = model.settings.outputLocation {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .help(path)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                }
                sliderRow("JPEG quality", value: $model.settings.jpegQuality, in: 0.4...1, display: "\(Int((model.settings.jpegQuality * 100).rounded()))%")
                sliderRow("HEIC quality", value: $model.settings.heicQuality, in: 0.4...1, display: "\(Int((model.settings.heicQuality * 100).rounded()))%")
                sliderRow("PDF render", value: $model.settings.pdfRenderDPI, in: 72...600, display: "\(Int(model.settings.pdfRenderDPI.rounded())) DPI")
            }
            Section("Video") {
                Picker("Codec", selection: $model.settings.videoCodec) {
                    Text("H.264 (videotoolbox, else libx264)").tag(VideoCodecPreference.h264)
                    Text("HEVC (videotoolbox, else libx265)").tag(VideoCodecPreference.hevc)
                }
                sliderRow("Bitrate", value: $model.settings.videoBitrateMbps, in: 0.5...40, display: String(format: "%.1f Mbps", model.settings.videoBitrateMbps))
            }
            Section("External tools") {
                toolRow("ffmpeg", path: model.tools.ffmpeg, brew: ExternalTool.ffmpeg.brewInstallLine, override: $model.settings.ffmpegOverride)
                toolRow("pandoc", path: model.tools.pandoc, brew: ExternalTool.pandoc.brewInstallLine, override: $model.settings.pandocOverride)
                toolRow("LibreOffice", path: model.tools.soffice, brew: ExternalTool.soffice.brewInstallLine, override: $model.settings.sofficeOverride)
                HStack {
                    Spacer()
                    Button("Rescan") { model.refreshTools() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Section("General") {
                Toggle("Launch at login", isOn: loginBinding)
                if !loginStatus.isEmpty {
                    caption(loginStatus)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                Toggle(isOn: $showMenuBarIcon) {
                    Text("Show icon in menu bar")
                    Text("When it's hidden, open Pith again (double-click it in Applications, or run open -a Pith) to get back to Settings.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .tint(PithTheme.highlight)
        .onAppear {
            refreshLoginCopy()
            normaliseFavourites()
        }
        .onChange(of: model.settings) { _, _ in
            model.save()
        }
    }

    private var locationBinding: Binding<Int> {
        Binding(
            get: {
                if case .directory = model.settings.outputLocation { return 1 }
                return 0
            },
            set: { newValue in
                if newValue == 0 {
                    model.settings.outputLocation = .besideSource
                } else if case .directory = model.settings.outputLocation {
                    return
                } else {
                    model.settings.outputLocation = .directory(NSHomeDirectory() + "/Downloads")
                }
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    model.settings.launchAtLogin = enabled
                    loginStatus = ""
                } catch {
                    loginStatus = error.localizedDescription
                }
                refreshLoginCopy()
            }
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Label at the leading edge; fixed-width slider and value column at the trailing edge.
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, display: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                // No `step:`: on macOS a stepped slider draws one tick per step,
                // which rendered as a solid line under the track.
                Slider(value: value, in: range)
                    .labelsHidden()
                    .frame(width: Self.sliderWidth)
                Text(display)
                    .monospacedDigit()
                    .frame(width: Self.valueWidth, alignment: .trailing)
            }
        }
    }

    /// Options come from `FavouriteCatalog`: every label that wheel can show, grouped.
    /// The stored value stays the label string, so `Favourites.index` is unchanged.
    private func favouritePicker(_ title: String, kind: WheelKind, selection: Binding<String>) -> some View {
        let groups = FavouriteCatalog.groups(for: kind)
        let known = Set(groups.flatMap(\.labels))
        let current = selection.wrappedValue
        return Picker(title, selection: selection) {
            Text("None").tag("")
            if !current.isEmpty && !known.contains(current) {
                Text("\(current) (not on any wheel)").tag(current)
            }
            Divider()
            if groups.count == 1, let only = groups.first {
                ForEach(only.labels, id: \.self) { label in
                    Text(label).tag(label)
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.labels, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                }
            }
        }
        .pickerStyle(.menu)
    }

    /// Values typed into the old free-text fields ("jpg ", "copy path") snap to their picker label.
    private func normaliseFavourites() {
        let fields: [(WheelKind, Binding<String>)] = [(.convert, $favConvert), (.tools, $favTools), (.actions, $favActions)]
        for (kind, binding) in fields {
            let trimmed = binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !binding.wrappedValue.isEmpty { binding.wrappedValue = "" }
                continue
            }
            if let label = FavouriteCatalog.labels(for: kind).first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }),
               label != binding.wrappedValue {
                binding.wrappedValue = label
            }
        }
    }

    private func toolRow(_ name: String, path: String?, brew: String, override: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: path == nil ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(path == nil ? Color.secondary : Color.green)
                Text(name).font(.body.weight(.medium))
                Spacer(minLength: 12)
                Text(path ?? "Not found. Run scripts/install.sh --deps or \(brew)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path ?? brew)
            }
            TextField("", text: override, prompt: Text("Custom path (optional)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.outputLocation = .directory(url.path)
        }
    }

    private func refreshLoginCopy() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "Pith will open when you log in."
        case .requiresApproval: loginStatus = "macOS is waiting for approval in System Settings."
        case .notRegistered: loginStatus = ""
        default: loginStatus = ""
        }
    }
}

final class AppModel: ObservableObject {
    @Published var settings: PithSettings
    @Published var tools: ToolAvailability

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(PithSettings.self, from: data) {
            settings = stored
        } else {
            settings = .default
        }
        tools = .none
        refreshTools()
    }

    func refreshTools() {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        tools = ToolLocator.availability(settings: settings, pathEnvironment: env) { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static let key = "pith.settings.v1"
}
