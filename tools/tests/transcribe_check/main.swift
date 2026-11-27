import Cocoa

private let localization = ProcessInfo.processInfo.arguments.dropFirst().first.flatMap { path in
    NSDictionary(contentsOfFile: path) as? [String: String]
} ?? [:]

func L(_ key: String) -> String { localization[key] ?? key }

_ = NSApplication.shared
let form = ConsentForm()
let alert = NSAlert()
alert.messageText = L("Start transcribing?")
alert.informativeText = "Microphone and Mac audio are written as text only.\n\nSave to: ~/Meetings"
alert.accessoryView = form.view
let start = alert.addButton(withTitle: L("Start"))
alert.addButton(withTitle: L("Cancel"))
start.isEnabled = false
form.agreed = { start.isEnabled = $0 }
alert.window.initialFirstResponder = form.title
alert.layout()
alert.window.contentView?.layoutSubtreeIfNeeded()

let checkbox = form.agree
let checkboxFrame = form.view.convert(checkbox.bounds, from: checkbox)
precondition(!checkbox.isHiddenOrHasHiddenAncestor, "Consent checkbox is hidden")
precondition(checkboxFrame.size.width >= checkbox.fittingSize.width && checkboxFrame.size.height > 0,
             "Consent checkbox is compressed")
precondition(form.view.bounds.contains(checkboxFrame), "Consent checkbox is outside the accessory view")
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
