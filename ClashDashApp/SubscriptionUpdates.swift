import Foundation
import Observation
import BackgroundTasks
import ClashDashKit

@Observable @MainActor
final class SubscriptionUpdates {
    static let backgroundID = "app.clashdash.subscription-refresh"
    var intervalRaw = UserDefaults.standard.object(forKey: "subscriptions.refreshInterval") as? Int ?? SubscriptionRefreshInterval.daily.rawValue {
        didSet { UserDefaults.standard.set(intervalRaw, forKey: "subscriptions.refreshInterval") }
    }
    var interval: SubscriptionRefreshInterval { SubscriptionRefreshInterval(rawValue: intervalRaw) ?? .daily }
    func schedule(profiles: [Profile]) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundID)
        guard let due = profiles.compactMap({ interval.nextDue(for: $0) }).min() else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundID)
        request.earliestBeginDate = max(due, Date().addingTimeInterval(15 * 60))
        // iOS may decline scheduling (e.g. Background App Refresh disabled). Foreground checks remain available.
        try? BGTaskScheduler.shared.submit(request)
    }
}
