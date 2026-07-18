import WidgetKit
import SwiftUI

@main
struct FilumaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        TodayWidget()
        WorkSessionLiveActivity()
    }
}
