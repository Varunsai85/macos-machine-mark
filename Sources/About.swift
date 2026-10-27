import AppKit

// The "About Machine Mark" window: icon, name, what it is, which build this
// is, and links. Version, build and commit come from Info.plist (build.sh
// writes them).
final class AboutWindow: NSWindow {
    static let source = URL(string: "https://github.com/\(Updater.repo)")!
    static let original = URL(string: "https://github.com/erikrjohansson/omarchy-machine-mark")!

    var onCheckForUpdates: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "About Machine Mark"

        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String ?? "–"
        let commit = info["MachineMarkCommit"] as? String ?? ""

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 128).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 128).isActive = true

        let name = NSTextField(labelWithString: "Machine Mark")
        name.font = .systemFont(ofSize: 26, weight: .bold)

        let blurb = NSTextField(wrappingLabelWithString: "An “About This Mac” drawn from your Mac’s real specs, every mark made of round dots.")
        blurb.alignment = .center
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 280

        let facts = NSGridView(views: [
            [label("Version"), value(Updater.current)],
            [label("Build"), value(build)],
            [label("Commit"), commit.isEmpty ? value("–") : link(commit, #selector(openCommit))],
        ])
        facts.rowSpacing = 4
        facts.columnSpacing = 10
        facts.column(at: 0).xPlacement = .trailing
        facts.column(at: 1).xPlacement = .leading
        facts.setContentHuggingPriority(.required, for: .horizontal)
        facts.setContentHuggingPriority(.required, for: .vertical)

        let credit = NSButton(title: "A port of omarchy-machine-mark by Erik Johansson", target: self, action: #selector(openOriginal))
        credit.isBordered = false
        credit.contentTintColor = .tertiaryLabelColor
        credit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let buttons = NSStackView(views: [
            NSButton(title: "GitHub", target: self, action: #selector(openSource)),
            NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdates)),
        ])
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, name, blurb, facts, buttons, credit])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(24, after: blurb)
        stack.setCustomSpacing(28, after: facts)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 32, bottom: 20, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 360),
        ])
        contentView = content
        setContentSize(content.fittingSize)
        center()
    }

    func label(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.textColor = .secondaryLabelColor
        f.alignment = .right
        return f
    }

    func value(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        f.isSelectable = true
        return f
    }

    func link(_ s: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.linkColor,
        ])
        b.toolTip = "Show this commit on GitHub"
        return b
    }

    @objc func openSource() { NSWorkspace.shared.open(Self.source) }
    @objc func openOriginal() { NSWorkspace.shared.open(Self.original) }
    @objc func checkForUpdates() { onCheckForUpdates() }
    @objc func openCommit() {
        guard let commit = Bundle.main.infoDictionary?["MachineMarkCommit"] as? String else { return }
        NSWorkspace.shared.open(Self.source.appendingPathComponent("commit/\(commit)"))
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}
