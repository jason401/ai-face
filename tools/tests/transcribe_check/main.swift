import Cocoa

private let localization = ProcessInfo.processInfo.arguments.dropFirst().first.flatMap { path in
    NSDictionary(contentsOfFile: path) as? [String: String]
} ?? [:]

func L(_ key: String) -> String { localization[key] ?? key }

_ = NSApplication.shared
let alert = NSAlert()
alert.messageText = L("Start transcribing?")
alert.informativeText = "Microphone and Mac audio are written as text only.\n\nSave to: ~/Meetings"
let form = ConsentForm(alert: alert)
let start = alert.addButton(withTitle: L("Start"))
alert.addButton(withTitle: L("Cancel"))
start.isEnabled = false
form.agreed = { start.isEnabled = $0 }
alert.window.initialFirstResponder = form.title
alert.layout()
alert.window.contentView?.layoutSubtreeIfNeeded()

let checkbox = form.agree
// NSAlert's own checkbox (drawn by the alert), with our title, unchecked.
precondition(checkbox === alert.suppressionButton, "Consent must use the alert's own checkbox")
precondition(checkbox.title == L("Everyone in the conversation agreed"), "Consent checkbox title")
let content = alert.window.contentView!
let checkboxFrame = content.convert(checkbox.bounds, from: checkbox)
precondition(!checkbox.isHiddenOrHasHiddenAncestor, "Consent checkbox is hidden")
precondition(checkboxFrame.size.width >= checkbox.fittingSize.width - 1 && checkboxFrame.size.height > 0,
             "Consent checkbox is compressed")
precondition(content.bounds.contains(checkboxFrame), "Consent checkbox is outside the alert")
// The test lays out the alert without ordering its window onto the user's screen.
var ancestor = checkbox.superview
while let view = ancestor {
    let frame = view.convert(checkbox.bounds, from: checkbox)
    precondition(view.bounds.contains(frame), "Consent checkbox is clipped by \(type(of: view))")
    ancestor = view.superview
}
precondition(checkbox.state == .off && !start.isEnabled, "Consent must start unchecked")
checkbox.performClick(nil)
precondition(checkbox.state == .on && start.isEnabled, "Checking consent must enable Start")
checkbox.performClick(nil)
precondition(checkbox.state == .off && !start.isEnabled, "Unchecking consent must disable Start")
print("consent form: OK")
