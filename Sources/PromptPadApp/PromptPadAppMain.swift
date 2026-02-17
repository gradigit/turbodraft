import AppKit

@main
struct PromptPadAppMain {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    let startHidden = CommandLine.arguments.contains("--start-hidden")
    app.setActivationPolicy(startHidden ? .accessory : .regular)
    app.delegate = delegate
    if !startHidden {
      app.activate(ignoringOtherApps: true)
    }
    app.run()
  }
}
