import AppKit
import Carbon.HIToolbox
import NotchbanCore
import SwiftUI

/// Borderless, but it can take the keyboard: the board inside is driven by keys.
final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    let state = BoardState()
    var panel: NSPanel!
    var notch = CGSize(width: 200, height: 32)
    private var pending: DispatchWorkItem?
    private var closing: DispatchWorkItem?
    private var closedAt = Date.distantPast
    private var offered = false
    private var keyMonitor: Any?
    /// The pill is just wide enough for an ear (rings with their count, figures) on each side of the notch.
    var pillWidth: CGFloat { notch.width + 210 }
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .darkAqua)  // the board is always the logo's ink, whatever the system looks like
        if let screen = NSScreen.main {
            notch.height = max(screen.safeAreaInsets.top, 24)
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notch.width = screen.frame.width - left.width - right.width
            }
        }
        panel = BoardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.delegate = self
        let host = NSHostingView(rootView: NotchView(state: state, notch: notch, width: pillWidth) { [weak self] in self?.set(expanded: true) }
            .environmentObject(model))
        let tracking = HoverView(frame: .zero)
        tracking.onChange = { [weak self] inside in self?.pointer(inside) }
        tracking.addSubview(host)
        host.autoresizingMask = [.width, .height]
        panel.contentView = tracking
        set(expanded: false)
        panel.orderFrontRegardless()
        model.start()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.reveal, self.panel.isKeyWindow, event.window === self.panel else { return event }
            let textFocused = self.panel.firstResponder is NSText
            if self.state.handle(event, board: self.model.board(self.state.path), boards: self.model.boards, textFocused: textFocused) {
                return nil
            }
            if event.keyCode == 53 { self.set(expanded: false); return nil }  // Esc with nothing left to back out of
            return event
        }
        registerHotKey()
        // `notchban <board>` opens that board at launch (the folder name, e.g. `notchban myapp`).
        if let name = CommandLine.arguments.dropFirst().first {
            Task { @MainActor in
                for _ in 0..<50 where model.boards.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
                if let path = model.boards.first(where: { $0.name == name })?.path { state.show(path) }
                set(expanded: true)
            }
        }
    }

    /// Out of the notch with a slight overshoot; back in quicker, fast first and soft into the notch.
    static func motion(opening: Bool) -> Animation {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return .easeOut(duration: 0.12) }
        return opening ? .spring(response: 0.5, dampingFraction: 0.8) : .timingCurve(0.3, 0, 0.15, 1, duration: 0.32)
    }

    /// Open: the panel takes its full size at once and the notch's outline swells into the board (a clip, so nothing is laid out twice).
    /// Closed: the board draws back into the notch, and only then does the panel shrink to the pill.
    /// Opened by the pointer it only shows: the app the person types in keeps the keyboard until they click the board.
    func set(expanded: Bool, keys: Bool = true) {
        guard let screen = NSScreen.main else { return }
        closing?.cancel()
        func place(_ size: CGSize) {
            panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                                  width: size.width, height: size.height), display: true, animate: false)
        }
        let pill = CGSize(width: pillWidth, height: notch.height)
        if expanded {
            place(CGSize(width: screen.frame.width * 0.9 + NotchView.margin * 2, height: screen.frame.height * 0.8 + notch.height + NotchView.margin))
            model.expanded = true
            DispatchQueue.main.async { withAnimation(Self.motion(opening: true)) { self.model.reveal = true } }
            if keys { takeKeys() } else { panel.orderFrontRegardless() }
        } else if model.expanded {
            closedAt = Date()
            state.palette = false
            withAnimation(Self.motion(opening: false)) { model.reveal = false }
            let work = DispatchWorkItem { [weak self] in
                self?.model.expanded = false
                place(pill)
            }
            closing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            place(pill)
        }
    }

    /// The board takes the keyboard: a click on the pill or ⌥⌘B, never the pointer passing by.
    private func takeKeys() {
        if !offered {  // the projects folder and the two one-time offers (skill, Claude's limits) wait until the board is opened: the person is there to answer
            offered = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [model] in
                if UserDefaults.standard.url(forKey: "root") == nil { model.chooseRoot() }  // where the projects live is the person's to say
                Skill.offerIfMissing(); Skill.offerUsageFeed()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // The search field would take focus as the first key view; the board's keys need it free.
        DispatchQueue.main.async { [weak self] in self?.panel.makeFirstResponder(nil) }
    }

    /// The pointer on the pill opens the board; off the open board, it closes again (after a breath, so a slip does not).
    func pointer(_ inside: Bool) {
        pending?.cancel()
        guard inside != model.reveal, !(inside && Date().timeIntervalSince(closedAt) < 1) else { return }
        let work = DispatchWorkItem { [weak self] in self?.set(expanded: inside, keys: false) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.18 : 0.5), execute: work)
    }

    /// Clicking anywhere else closes the board.
    func windowDidResignKey(_ notification: Notification) {
        if model.reveal { set(expanded: false) }
    }

    /// ⌥⌘B anywhere opens or closes the board (Carbon hot keys need no Accessibility permission).
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in (NSApp.delegate as? Delegate)?.toggleBoard() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x4E424E42, id: 1),
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    /// A board the pointer opened takes the keys; otherwise the board opens or closes.
    private func toggleBoard() { model.reveal && !panel.isKeyWindow ? takeKeys() : set(expanded: !model.reveal) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    app.run()
}

/// Reports the pointer entering or leaving the panel.
final class HoverView: NSView {
    var onChange: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}
