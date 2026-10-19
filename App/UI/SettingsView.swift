import AppKit
import ServiceManagement
import SwiftUI
import PithCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var loginStatus = ""

    var body: some View {
        Form {
            Section("Wheels") {
                keyPicker("Convert", key: $model.settings.bindings.convert)
                keyPicker("Tools", key: $model.settings.bindings.tools)
                keyPicker("Actions", key: $model.settings.bindings.actions)
                Text("Tap the key while dragging a file. Hold longer than \(Int(model.settings.bindings.tapMaxDuration * 1000)) ms and it won't open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Output") {
                Picker("Location", selection: locationBinding) {
                    Text("Next to the source").tag(0)
                    Text("Fixed folder").tag(1)
                }
                .pickerStyle(.radioGroup)
                if case let .directory(path) = model.settings.outputLocation {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                qualitySlider("JPEG quality", value: $model.settings.jpegQuality)
                qualitySlider("HEIC quality", value: $model.settings.heicQuality)
                HStack {
                    Text("PDF render")
                    Slider(value: $model.settings.pdfRenderDPI, in: 72...600, step: 1)
                    Text("\(Int(model.settings.pdfRenderDPI)) DPI")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }
            Section("Video") {
                Picker("Codec", selection: $model.settings.videoCodec) {
                    Text("H.264 (videotoolbox, else libx264)").tag(VideoCodecPreference.h264)
                    Text("HEVC (videotoolbox, else libx265)").tag(VideoCodecPreference.hevc)
                }
                HStack {
                    Text("Bitrate")
                    Slider(value: $model.settings.videoBitrateMbps, in: 0.5...40)
                    Text(String(format: "%.1f Mbps", model.settings.videoBitrateMbps))
                        .frame(width: 88, alignment: .trailing)
                }
            }
            Section("External tools") {
                toolRow("ffmpeg", path: model.tools.ffmpeg, brew: ExternalTool.ffmpeg.brewInstallLine, override: $model.settings.ffmpegOverride)
                toolRow("pandoc", path: model.tools.pandoc, brew: ExternalTool.pandoc.brewInstallLine, override: $model.settings.pandocOverride)
                toolRow("LibreOffice", path: model.tools.soffice, brew: ExternalTool.soffice.brewInstallLine, override: $model.settings.sofficeOverride)
                Button("Rescan") { model.refreshTools() }
            }
            Section("General") {
                Toggle("Launch at login", isOn: loginBinding)
                if !loginStatus.isEmpty {
                    Text(loginStatus).font(.callout).foregroundStyle(.secondary)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .padding(8)
        .tint(PithTheme.highlight)
        .onAppear { refreshLoginCopy() }
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

    private func keyPicker(_ title: String, key: Binding<TriggerKey>) -> some View {
        Picker(title, selection: key) {
            ForEach(TriggerKey.allCases, id: \.self) { trigger in
                Text(trigger.rawValue.capitalized).tag(trigger)
            }
        }
    }

    private func qualitySlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0.4...1)
            Text("\(Int(value.wrappedValue * 100))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func toolRow(_ name: String, path: String?, brew: String, override: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path ?? "Not found — \(brew)")
                .font(.callout)
                .foregroundStyle(path == nil ? .secondary : .primary)
            TextField("Override path", text: override)
                .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
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
