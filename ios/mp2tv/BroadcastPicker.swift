import ReplayKit
import SwiftUI

/// 系统录屏选择按钮（iOS 17–26 路线）：用户点它弹出 broadcast picker，
/// 选中 mp2tv 录屏扩展后开始投屏。扩展自持会话，见 SampleHandler。
struct BroadcastPicker: UIViewRepresentable {

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        v.preferredExtension = "com.mp2tv.app.broadcast"
        v.showsMicrophoneButton = false
        return v
    }

    func updateUIView(_ v: RPSystemBroadcastPickerView, context: Context) {}
}
