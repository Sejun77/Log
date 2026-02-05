import Foundation
import ActivityKit

public struct RestActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var endDate: Date
        public var sessionStart: Date?

        public init(endDate: Date, sessionStart: Date?) {
            self.endDate = endDate
            self.sessionStart = sessionStart
        }
    }
}
