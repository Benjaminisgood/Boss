import Foundation

struct CronParser {
    static func nextDate(expression: String, after date: Date) -> Date? {
        let parts = expression.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return nil }

        let calendar = Calendar.current
        var current = calendar.date(byAdding: .minute, value: 1, to: date) ?? date

        for _ in 0..<1000 {
            if matches(expression: expression, date: current) {
                return current
            }
            current = calendar.date(byAdding: .minute, value: 1, to: current) ?? current
        }
        return nil
    }

    private static func matches(expression: String, date: Date) -> Bool {
        let parts = expression.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return false }

        let calendar = Calendar.current
        let values = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        let weekday = values.weekday ?? 1

        return matchesField(parts[0], value: values.minute ?? 0, min: 0, max: 59)
            && matchesField(parts[1], value: values.hour ?? 0, min: 0, max: 23)
            && matchesField(parts[2], value: values.day ?? 1, min: 1, max: 31)
            && matchesField(parts[3], value: values.month ?? 1, min: 1, max: 12)
            && matchesField(parts[4], value: weekday == 1 ? 7 : weekday - 1, min: 1, max: 7)
    }

    private static func matchesField(_ field: String, value: Int, min: Int, max: Int) -> Bool {
        if field == "*" {
            return true
        }

        if field.contains(",") {
            let items = field.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return items.contains { matchesSingleField($0, value: value, min: min, max: max) }
        }

        return matchesSingleField(field, value: value, min: min, max: max)
    }

    private static func matchesSingleField(_ field: String, value: Int, min: Int, max: Int) -> Bool {
        if field == "*" {
            return true
        }

        if field.contains("/") {
            let parts = field.split(separator: "/")
            guard parts.count == 2, let step = Int(parts[1]), step > 0 else { return false }
            let base = String(parts[0])

            if base == "*" {
                return value % step == 0
            }

            if base.contains("-") {
                let range = base.split(separator: "-")
                guard range.count == 2,
                      let start = Int(range[0]),
                      let end = Int(range[1]),
                      start <= end,
                      (min...max).contains(start),
                      (min...max).contains(end) else { return false }
                guard value >= start && value <= end else { return false }
                return (value - start) % step == 0
            }

            return false
        }

        if field.contains("-") {
            let range = field.split(separator: "-")
            guard range.count == 2,
                  let start = Int(range[0]),
                  let end = Int(range[1]),
                  start <= end,
                  (min...max).contains(start),
                  (min...max).contains(end) else { return false }
            return value >= start && value <= end
        }

        guard let exact = Int(field), (min...max).contains(exact) else {
            return false
        }
        return value == exact
    }
}
