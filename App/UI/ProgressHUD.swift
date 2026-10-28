import AppKit
import SwiftUI

struct ProgressHUDView: View {
    var title: String
    var subtitle: String
    var progress: Double
    var onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(PithTheme.ink.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.35)))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PithTheme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(PithTheme.ink.opacity(0.62))
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.16))
                        Capsule()
                            .fill(PithTheme.ink.opacity(0.78))
                            .frame(width: max(4, geo.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 3)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 286)
        .background {
            DesktopBlur(material: .hudWindow)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.28))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(PithTheme.cream.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
    }
}

struct HUDJob: Identifiable, Equatable {
    var id: UUID
    var title: String
    var subtitle: String
    var progress: Double
    var anchor: CGPoint
}

final class HUDPanelController {
    private var panels: [UUID: NSPanel] = [:]
    /// Insertion order. Dictionary key order is not stable, and cards were jumping as jobs updated.
    private var order: [UUID] = []

    func upsert(_ job: HUDJob) {
        let isNew = panels[job.id] == nil
        let panel = panels[job.id] ?? makePanel()
        if isNew {
            panels[job.id] = panel
            order.append(job.id)
        }
        let root = ProgressHUDView(title: job.title, subtitle: job.subtitle, progress: job.progress) { [weak self] in
            self?.onCancel?(job.id)
        }
        if let host = panel.contentView as? NSHostingView<ProgressHUDView> {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 286, height: 78)
            panel.contentView = host
        }
        place(job, on: panel)
        if isNew || !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Moves a card without rebuilding its SwiftUI tree. Used when a sibling is removed.
    func place(_ job: HUDJob) {
        guard let panel = panels[job.id] else { return }
        place(job, on: panel)
    }

    func remove(_ id: UUID) {
        panels[id]?.orderOut(nil)
        panels[id] = nil
        order.removeAll { $0 == id }
    }

    func removeAll() {
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        order.removeAll()
    }

    var onCancel: ((UUID) -> Void)?

    private func place(_ job: HUDJob, on panel: NSPanel) {
        let frame = frame(for: job)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func frame(for job: HUDJob) -> NSRect {
        let size = NSSize(width: 286, height: 78)
        let stacked = CGFloat(stackIndex(of: job.id)) * (size.height + 8)
        let origin = NSPoint(x: job.anchor.x + 28, y: job.anchor.y - size.height - 28 - stacked)
        return NSRect(origin: origin, size: size)
    }

    private func stackIndex(of id: UUID) -> Int {
        order.firstIndex(of: id) ?? order.count
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 286, height: 78),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        return panel
    }
}
