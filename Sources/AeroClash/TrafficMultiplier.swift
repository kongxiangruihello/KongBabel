import Foundation

/// 从节点名称中识别“流量倍率”，例如“日本-JP1-流量倍率:0.2”“香港 [0.5x]”“美国 ×2”“新加坡 2倍”。
enum TrafficMultiplier {
    private static let patterns: [NSRegularExpression] = [
        #"(?:倍率|倍数|rate)\s*[:：=]?\s*([0-9]+(?:\.[0-9]+)?)"#,
        #"([0-9]+(?:\.[0-9]+)?)\s*(?:倍|[xX×])(?![A-Za-z0-9])"#,
        #"(?<![A-Za-z0-9])[xX×]\s*([0-9]+(?:\.[0-9]+)?)(?![0-9])"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// 识别不到时返回 nil（按 1 倍计算）
    static func parse(_ name: String) -> Double? {
        let range = NSRange(name.startIndex..., in: name)
        for regex in patterns {
            guard let match = regex.firstMatch(in: name, range: range), match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: name),
                  let value = Double(name[valueRange]), value > 0, value <= 100 else { continue }
            return value
        }
        return nil
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// 节点旁显示的标签，例如 “×0.2”
    static func label(_ value: Double) -> String { "×" + format(value) }
}

/// 某一天经代理的实际流量，以及按倍率折算后扣除的订阅流量。
struct ChargedTrafficDay: Codable, Equatable {
    let day: String
    var actualBytes: Int64
    var chargedBytes: Int64
}

/// 订阅流量消耗记录：保存在应用支持目录的 charged-traffic.json，保留最近 90 天。
struct ChargedTrafficStore {
    static let keepDays = 90
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("charged-traffic.json")
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func load() -> [ChargedTrafficDay] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChargedTrafficDay].self, from: data)) ?? []
    }

    /// 把一段时间的流量记到某一天，返回更新后的全部记录
    func record(actual: Int64, charged: Int64, on date: Date = Date(), into days: [ChargedTrafficDay]) -> [ChargedTrafficDay] {
        var updated = days
        let key = Self.dayKey(date)
        if let index = updated.firstIndex(where: { $0.day == key }) {
            updated[index].actualBytes += actual
            updated[index].chargedBytes += charged
        } else {
            updated.append(ChargedTrafficDay(day: key, actualBytes: actual, chargedBytes: charged))
        }
        updated.sort { $0.day < $1.day }
        if updated.count > Self.keepDays { updated.removeFirst(updated.count - Self.keepDays) }
        if let data = try? JSONEncoder().encode(updated) { try? data.write(to: url, options: .atomic) }
        return updated
    }

    /// 今日、本月扣除的订阅流量，以及最近 7 天（不含今天）平均每天扣除
    static func summary(of days: [ChargedTrafficDay], now: Date = Date()) -> (today: ChargedTrafficDay, month: Int64, dailyAverage: Double) {
        let todayKey = dayKey(now)
        let monthPrefix = String(todayKey.prefix(7))
        let today = days.first { $0.day == todayKey } ?? ChargedTrafficDay(day: todayKey, actualBytes: 0, chargedBytes: 0)
        let month = days.filter { $0.day.hasPrefix(monthPrefix) }.reduce(Int64(0)) { $0 + $1.chargedBytes }
        let recentKeys = (1...7).compactMap { offset in Calendar.current.date(byAdding: .day, value: -offset, to: now).map(dayKey) }
        let recent = days.filter { recentKeys.contains($0.day) }
        let average = recent.isEmpty ? 0 : Double(recent.reduce(Int64(0)) { $0 + $1.chargedBytes }) / Double(recent.count)
        return (today, month, average)
    }
}
