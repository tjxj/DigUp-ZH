import AppKit

/// This fork never contacts the upstream updater or installs an upstream build.
/// The user's explicit action opens this fork's releases.
final class Updates {
    private let model: AppModel
    var onSessionEnded: () -> Void = {}
    init(model: AppModel) { self.model = model }
    func start() {}
    var automaticallyChecks: Bool {
        get { false }
        set { }
    }
    var canCheck: Bool { true }
    func checkNow() {
        NSWorkspace.shared.open(URL(string: "https://github.com/tjxj/DigUp-ZH/releases")!)
    }
    func checkInBackground() {}
}
