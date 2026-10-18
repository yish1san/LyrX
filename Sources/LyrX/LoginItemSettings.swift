import AppKit
import ServiceManagement
import SwiftUI

enum LoginItemState: Equatable { case disabled, enabled, requiresApproval, unavailable }

@MainActor
protocol LoginItemService {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
private struct SystemLoginItemService: LoginItemService {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// 预览只改内存，不注册真实登录项。
@MainActor
private final class PreviewLoginItemService: LoginItemService {
    var state: LoginItemState = .disabled
    func register() { state = .enabled }
    func unregister() { state = .disabled }
    func openSettings() {}
}

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var state: LoginItemState = .disabled
    @Published private(set) var errorMessage: String?
    private let service: any LoginItemService

    init(service: (any LoginItemService)? = nil, preview: Bool = AppIdentity.isPreview) {
        self.service = service ?? (preview ? PreviewLoginItemService() : SystemLoginItemService())
        refresh()
    }

    var isEnabled: Bool { state == .enabled || state == .requiresApproval }
    func refresh() { state = service.state }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()
        guard enabled != isEnabled else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            refresh()
            // 系统已达到目标状态时，忽略重复注册／注销产生的错误。
            if isEnabled != enabled { errorMessage = "未能修改登录项，请将 LyrX 放入“应用程序”后重试。" }
        }
        refresh()
    }

    func openSettings() { service.openSettings() }
}

struct LoginItemSection: View {
    @StateObject private var loginItems = LoginItemSettings()

    var body: some View {
        Section("启动") {
            Toggle("登录时启动 LyrX", isOn: Binding(get: { loginItems.isEnabled }, set: { loginItems.setEnabled($0) }))
                .help("登录 Mac 后自动打开 LyrX。")
            if loginItems.state == .requiresApproval {
                Text("需要在系统设置中允许 LyrX 登录时启动。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开登录项设置…") { loginItems.openSettings() }
            } else if loginItems.state == .unavailable {
                Text("请先将 LyrX 放入“应用程序”，再开启登录时启动。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = loginItems.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { loginItems.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItems.refresh()
        }
    }
}
