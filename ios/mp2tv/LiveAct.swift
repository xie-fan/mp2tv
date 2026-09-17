import ActivityKit
import Foundation
import UIKit

/// 实时活动管理（App 侧）。扩展侧视图在 mp2tvWidget/。
@available(iOS 16.2, *)
enum LiveAct {
    private(set) static var activity: Activity<Mp2tvAttributes>?

    static func update(receiverName: String, status: String, cropOn: Bool, forceRot: Int) {
        if #available(iOS 17.0, *), ActivityAuthorizationInfo().areActivitiesEnabled {
            let state = Mp2tvAttributes.ContentState(
                status: status, cropOn: cropOn, forceRot: forceRot)
            if let a = activity {
                Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
            } else {
                let attrs = Mp2tvAttributes(receiverName: receiverName)
                activity = try? Activity.request(attributes: attrs,
                                                 content: ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    static func end() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
