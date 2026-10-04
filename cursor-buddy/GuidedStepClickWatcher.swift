//
//  GuidedStepClickWatcher.swift
//  cursor-buddy
//

import AppKit
import Foundation

/// Watches for the user clicking the spot OpenClicky pointed at during a
/// step-by-step walkthrough. It only observes: clicks are never consumed,
/// so menus and buttons under the pointer behave exactly as usual.
@MainActor
final class GuidedStepClickWatcher {
    /// How far from the pointed spot a click still counts as "that spot".
    /// Pointing lands on the middle of a control, clicks land anywhere on it.
    static let acceptanceRadius: CGFloat = 60
    /// A walkthrough the user has walked away from stops waiting.
    static let timeoutSeconds: TimeInterval = 90

    private(set) var isArmed = false
    private var target: CGPoint = .zero
    private var globalClickMonitor: Any?
    private var timeoutTask: Task<Void, Never>?
    private var onClick: (@MainActor () -> Void)?
    private var onTimeout: (@MainActor () -> Void)?

    func arm(
        target: CGPoint,
        onClick: @escaping @MainActor () -> Void,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        disarm()
        self.target = target
        self.onClick = onClick
        self.onTimeout = onTimeout
        isArmed = true

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(at: clickLocation)
            }
        }

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleTimeout()
            }
        }
    }

    func disarm() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        globalClickMonitor = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        onClick = nil
        onTimeout = nil
        isArmed = false
    }

    private func handleClick(at location: CGPoint) {
        guard isArmed else { return }
        let distance = hypot(location.x - target.x, location.y - target.y)
        guard distance <= Self.acceptanceRadius else { return }
        let callback = onClick
        disarm()
        callback?()
    }

    private func handleTimeout() {
        guard isArmed else { return }
        let callback = onTimeout
        disarm()
        callback?()
    }
}
