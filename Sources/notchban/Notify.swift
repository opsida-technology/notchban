import Foundation
import NotchbanCore
import UserNotifications

/// One notification when a card lands in Human Review, with the line saying what it needs. Off until the owner turns it
/// on in the board switcher's menu; macOS asks for its own permission then.
enum Notifier {
    /// A build run straight from `swift run` has no bundle to notify from.
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func ask() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ board: Board, _ card: Card) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(card.id) needs you"
        content.subtitle = "\(board.displayName) · \(card.title)"
        if let needs = card.needs { content.body = needs }
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "review-\(board.path)-\(card.id)", content: content, trigger: nil))
    }
}
