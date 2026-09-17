import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 实时活动：灵动岛 + 锁屏卡片，带 旋转/截取/退出 三个交互按钮。
@available(iOS 16.2, *)
struct Mp2tvActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: Mp2tvAttributes.self) { ctx in
            // 锁屏/通知中心卡片
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ctx.state.status).font(.headline)
                    Text(ctx.attributes.receiverName).font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if #available(iOS 17.0, *) {
                    Button(intent: RotateIntent()) {
                        Image(systemName: "rotate.right")
                    }
                    Button(intent: CropIntent()) {
                        Image(systemName: ctx.state.cropOn ? "crop" : "rectangle")
                    }
                    Button(intent: StopCastIntent()) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(ctx.attributes.receiverName, systemImage: "display")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(ctx.state.status).font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if #available(iOS 17.0, *) {
                        HStack {
                            Button(intent: RotateIntent()) {
                                Image(systemName: "rotate.right")
                            }
                            Button(intent: CropIntent()) {
                                Image(systemName: ctx.state.cropOn ? "crop" : "rectangle")
                            }
                            Button(intent: StopCastIntent()) {
                                Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "display")
            } compactTrailing: {
                Image(systemName: ctx.state.forceRot == 0 ? "dot.radiowaves.right" : "rotate.right")
            } minimal: {
                Image(systemName: "display")
            }
        }
    }
}
