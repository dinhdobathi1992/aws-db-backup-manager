// AWS DB Backup Manager v0.2: native SwiftUI shell, single process.
import ADBMCore
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running unbundled (swift run) needs a regular activation policy to get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BackupManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel(service: ServiceFactory.make())

    var body: some Scene {
        Window("AWS DB Backup Manager", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { model.theme.apply() }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                Button("Jump to…") { model.paletteOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Refresh") { model.refreshActive() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.activeAccountId == nil || model.selection == .settings || model.selection == .fleet)
                Divider()
                ForEach(Array(Tab.allCases.enumerated()), id: \.element) { i, tab in
                    Button(tab.label) { model.select(.tab(tab)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("All accounts") { model.select(.fleet) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Settings") { model.select(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Picker("Appearance", selection: Bindable(model).theme) {
                    ForEach(ThemeSetting.allCases) { Text($0.label).tag($0) }
                }
            }
        }
    }
}
