//
//  IslandAskWidgetLiveActivity.swift
//  IslandAskWidget
//
//  Created by Wentao Xie on 2026/11/1.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct IslandAskWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct IslandAskWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IslandAskWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension IslandAskWidgetAttributes {
    fileprivate static var preview: IslandAskWidgetAttributes {
        IslandAskWidgetAttributes(name: "World")
    }
}

extension IslandAskWidgetAttributes.ContentState {
    fileprivate static var smiley: IslandAskWidgetAttributes.ContentState {
        IslandAskWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: IslandAskWidgetAttributes.ContentState {
         IslandAskWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: IslandAskWidgetAttributes.preview) {
   IslandAskWidgetLiveActivity()
} contentStates: {
    IslandAskWidgetAttributes.ContentState.smiley
    IslandAskWidgetAttributes.ContentState.starEyes
}
