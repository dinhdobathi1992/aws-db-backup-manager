// Schedule math for the read-only schedules view: a port of
// internal/inventory/schedules.go's window/cron helpers, including a
// faithful port of robfig/cron v3's ParseStandard + SpecSchedule.Next (the
// library v0.1 used), since this package has no third-party dependencies.
import Foundation

public enum Cron {
    /// The next UTC occurrence of an RDS preferred backup window's start
    /// time ("hh24:mi-hh24:mi"), or nil if the window is malformed.
    public static func nextAutomatedWindowRun(_ window: String, after: Date) -> String? {
        guard let dash = window.firstIndex(of: "-") else { return nil }
        let start = window[..<dash]
        // Go time.Parse("15:04"): a one- or two-digit hour, a two-digit minute.
        let parts = start.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let h = Int(parts[0]), let m = Int(parts[1]), h < 24, m < 60 else { return nil }
        let cal = utcCalendar
        var c = cal.dateComponents([.year, .month, .day], from: after)
        c.hour = h; c.minute = m; c.second = 0
        guard var next = cal.date(from: c) else { return nil }
        if !(next > after) { next = next.addingTimeInterval(24 * 3600) }
        return RFC3339.string(next)
    }

    /// Normalizes an AWS six-field cron ("cron(0 5 * * ? *)") to the five
    /// standard fields, mapping "?" to "*". Nil unless exactly six fields.
    public static func normalizeAWSCron(_ expr: String) -> [String]? {
        var e = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.hasPrefix("cron(") { e.removeFirst(5) }
        if e.hasSuffix(")") { e.removeLast() }
        let f = e.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
        guard f.count == 6 else { return nil }
        return [f[0], f[1], f[2] == "?" ? "*" : f[2], f[3], f[4] == "?" ? "*" : f[4]]
    }

    /// The next run of an AWS Backup rule's cron after `after`, or nil if
    /// the expression is malformed. AWS Backup evaluates cron in UTC, so
    /// that is the default time zone.
    public static func parseAWSCronNextRun(_ expr: String, after: Date, timeZone: TimeZone = .gmt) -> String? {
        guard let fields = normalizeAWSCron(expr), let spec = try? Spec.parseStandard(fields.joined(separator: " ")) else { return nil }
        guard let next = spec.next(after, timeZone: timeZone) else { return "0001-01-01T00:00:00Z" }
        return RFC3339.string(next)
    }

    static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }

    struct ParseError: Error { let message: String }

    /// robfig/cron SpecSchedule: one bit per allowed value, plus a star bit.
    struct Spec {
        static let starBit: UInt64 = 1 << 63
        var minute: UInt64, hour: UInt64, dom: UInt64, month: UInt64, dow: UInt64

        struct Bounds { let min: UInt, max: UInt; let names: [String: UInt] }
        static let minutes = Bounds(min: 0, max: 59, names: [:])
        static let hours = Bounds(min: 0, max: 23, names: [:])
        static let doms = Bounds(min: 1, max: 31, names: [:])
        static let months = Bounds(min: 1, max: 12, names: ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                                             "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12])
        static let dows = Bounds(min: 0, max: 6, names: ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6])

        static func parseStandard(_ spec: String) throws -> Spec {
            guard !spec.isEmpty else { throw ParseError(message: "empty spec string") }
            if spec.hasPrefix("@") { throw ParseError(message: "descriptors are not supported") }
            let f = spec.split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count == 5 else { throw ParseError(message: "expected exactly 5 fields, found \(f.count): \(spec)") }
            return Spec(minute: try field(f[0], minutes), hour: try field(f[1], hours), dom: try field(f[2], doms),
                        month: try field(f[3], months), dow: try field(f[4], dows))
        }

        static func field(_ s: String, _ r: Bounds) throws -> UInt64 {
            var bits: UInt64 = 0
            for expr in s.split(separator: ",", omittingEmptySubsequences: false) {
                bits |= try range(String(expr), r)
            }
            return bits
        }

        static func range(_ expr: String, _ r: Bounds) throws -> UInt64 {
            let rangeAndStep = expr.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let lowAndHigh = rangeAndStep[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            let single = lowAndHigh.count == 1
            var start: UInt, end: UInt, step: UInt
            var extra: UInt64 = 0
            if lowAndHigh[0] == "*" || lowAndHigh[0] == "?" {
                start = r.min; end = r.max; extra = starBit
            } else {
                start = try intOrName(lowAndHigh[0], r.names)
                switch lowAndHigh.count {
                case 1: end = start
                case 2: end = try intOrName(lowAndHigh[1], r.names)
                default: throw ParseError(message: "too many hyphens: \(expr)")
                }
            }
            switch rangeAndStep.count {
            case 1: step = 1
            case 2:
                step = try mustInt(rangeAndStep[1])
                if single { end = r.max }   // "N/step" means "N-max/step"
                if step > 1 { extra = 0 }
            default: throw ParseError(message: "too many slashes: \(expr)")
            }
            if start < r.min { throw ParseError(message: "beginning of range (\(start)) below minimum (\(r.min)): \(expr)") }
            if end > r.max { throw ParseError(message: "end of range (\(end)) above maximum (\(r.max)): \(expr)") }
            if start > end { throw ParseError(message: "beginning of range (\(start)) beyond end of range (\(end)): \(expr)") }
            if step == 0 { throw ParseError(message: "step of range should be a positive number: \(expr)") }
            var bits: UInt64 = 0
            var i = start
            while i <= end { bits |= 1 << UInt64(i); i += step }
            return bits | extra
        }

        static func intOrName(_ s: String, _ names: [String: UInt]) throws -> UInt {
            if let v = names[s.lowercased()] { return v }
            return try mustInt(s)
        }

        static func mustInt(_ s: String) throws -> UInt {
            // Go strconv.Atoi accepts an optional sign; negatives are rejected.
            guard let n = Int(s) else { throw ParseError(message: "failed to parse int from \(s)") }
            guard n >= 0 else { throw ParseError(message: "negative number (\(n)) not allowed: \(s)") }
            return UInt(n)
        }

        func dayMatches(_ day: Int, _ weekday: Int) -> Bool {
            let domMatch = (UInt64(1) << UInt64(day)) & dom > 0
            let dowMatch = (UInt64(1) << UInt64(weekday)) & dow > 0
            if dom & Spec.starBit > 0 || dow & Spec.starBit > 0 { return domMatch && dowMatch }
            return domMatch || dowMatch
        }

        /// robfig SpecSchedule.Next with second bit 0 only (ParseStandard).
        /// Returns nil where robfig returns the zero time (nothing within
        /// five years).
        func next(_ after: Date, timeZone: TimeZone) -> Date? {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            // Start at the next whole second.
            var t = Date(timeIntervalSince1970: floor(after.timeIntervalSince1970) + 1)
            var added = false
            func c(_ d: Date) -> DateComponents { cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: d) }
            func make(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
                cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
            }
            let yearLimit = c(t).year! + 5

            wrap: while true {
                if c(t).year! > yearLimit { return nil }

                while (UInt64(1) << UInt64(c(t).month!)) & month == 0 {
                    if !added { added = true; let x = c(t); t = make(x.year!, x.month!, 1) }
                    t = cal.date(byAdding: .month, value: 1, to: t)!
                    if c(t).month! == 1 { continue wrap }
                }

                while !dayMatches(c(t).day!, c(t).weekday! - 1) {
                    if !added { added = true; let x = c(t); t = make(x.year!, x.month!, x.day!) }
                    t = cal.date(byAdding: .day, value: 1, to: t)!
                    if c(t).day! == 1 { continue wrap }
                }

                while (UInt64(1) << UInt64(c(t).hour!)) & hour == 0 {
                    if !added { added = true; let x = c(t); t = make(x.year!, x.month!, x.day!, x.hour!) }
                    t = t.addingTimeInterval(3600)
                    if c(t).hour! == 0 { continue wrap }
                }

                while (UInt64(1) << UInt64(c(t).minute!)) & minute == 0 {
                    if !added { added = true; t = Date(timeIntervalSince1970: floor(t.timeIntervalSince1970 / 60) * 60) }
                    t = t.addingTimeInterval(60)
                    if c(t).minute! == 0 { continue wrap }
                }

                while c(t).second! != 0 {
                    if !added { added = true; t = Date(timeIntervalSince1970: floor(t.timeIntervalSince1970)) }
                    t = t.addingTimeInterval(1)
                    if c(t).second! == 0 { continue wrap }
                }
                return t
            }
        }
    }
}
