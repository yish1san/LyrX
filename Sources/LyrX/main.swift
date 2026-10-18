import AppKit

MainActor.assumeIsolated {
    AppIdentity.prepareForLaunch()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // 无 Dock 图标，菜单栏常驻
    app.run() // 阻塞于主 runloop，delegate 生命周期随之保持
}
