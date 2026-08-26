import Foundation
import EventKit

extension EKEvent {
    /// The key series membership is stored against.
    ///
    /// `eventIdentifier` is reissued when EventKit rewrites an event — saving a
    /// notes change was enough to mint a new one, which silently dropped the
    /// event out of its series. `calendarItemExternalIdentifier` is the
    /// iCalendar UID and survives edits, so membership survives with it.
    var seriesKey: String {
        SeriesKey.normalize(calendarItemExternalIdentifier ?? eventIdentifier ?? "")
    }
}
