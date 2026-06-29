import Foundation
import UserNotifications

/// Local notifications for date-based reminders (PUC + insurance expiry), mirroring
/// OpenDash's reminder feature. Fires 7 days before expiry at 9am. Km-based service
/// intervals can't be time-scheduled, so those surface as a visual "due" flag in the
/// Garage instead.
final class ReminderService {
    static let shared = ReminderService()

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func reschedule(vehicles: [Vehicle]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for v in vehicles {
            schedule(vehicle: v.name, kind: "PUC", expiry: v.pucExpiry)
            schedule(vehicle: v.name, kind: "Insurance", expiry: v.insuranceExpiry)
        }
    }

    private func schedule(vehicle: String, kind: String, expiry: Date?) {
        guard let expiry else { return }
        let remindDate = Calendar.current.date(byAdding: .day, value: -7, to: expiry) ?? expiry
        guard remindDate > Date() else { return }

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: remindDate)
        comps.hour = 9

        let content = UNMutableNotificationContent()
        content.title = "\(kind) expiring soon"
        content.body = "\(vehicle): \(kind) expires \(expiry.formatted(date: .abbreviated, time: .omitted))."
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: "\(vehicle)-\(kind)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
        DiagnosticsLog.shared.log("reminder", "\(vehicle) \(kind) → notify \(remindDate.formatted(date: .abbreviated, time: .omitted))")
    }
}
