import SwiftUI
import WidgetKit

@main
struct Mp2tvActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            Mp2tvActivityWidget()
        }
    }
}
