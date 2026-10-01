import Foundation
import JMAPKit

extension Date {
    /// Time for today, weekday within the last week, otherwise a date.
    var listTimestamp: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, (0..<6).contains(days) {
            return formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.day().month(.abbreviated))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}

extension EmailAddress {
    var displayName: String {
        name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? email
    }

    var initials: String {
        let words = displayName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        return words.compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
