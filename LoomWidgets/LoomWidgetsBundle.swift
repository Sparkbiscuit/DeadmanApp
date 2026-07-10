import WidgetKit
import SwiftUI

@main
struct LoomWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        TodayWidget()
        WorkSessionLiveActivity()
    }
}
