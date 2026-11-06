import AppKit
import RecastCore
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if ["--convert", "--info", "--self-test", "--help"].contains(arguments.first ?? "") {
            exit(CommandLineTool.run(arguments))
        }
        RecastApp.main()
    }
}

struct RecastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Recast", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 620, minHeight: 420)
                .onAppear { Snapshot.runIfRequested(model) }
        }
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.chooseFiles() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Convert") { model.convert() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isConverting || model.convertibleCount == 0)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isConverting)
                Divider()
                Button("Remove Converted Files from List") { model.removeFinished() }
                    .disabled(model.isConverting)
                Button("Clear List") { model.clear() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.isConverting || model.items.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Settings" : "Show Settings") { model.showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened with "Open With" join the list.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard AppModel.shared.isConverting else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Recast is still converting."
            alert.informativeText = "If you quit now, the files being converted are left unfinished and removed. Your originals are untouched."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Keep Converting")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            AppModel.shared.stop()
            return .terminateNow
        }
    }
}
