import Foundation

/// OpenAI API list prices (Standard tier, USD per 1M tokens).
/// Source: https://developers.openai.com/api/docs/pricing (Markdown at `pricing.md`).
struct OpenAIPricing: Sendable {
    struct Rates: Sendable {
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double
        let output: Double
    }

    struct ModelPrice: Sendable {
        let short: Rates
        let long: Rates
    }

    static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing.md")!
    /// "Short context: ≤272K input tokens. Long context: >272K input tokens." (per request)
    static let longContextThreshold = 272_000

    let models: [String: ModelPrice]

    func price(for model: String) -> ModelPrice? {
        if let p = models[model] { return p }
        // Fall back to the longest listed model name that prefixes the ID (e.g. dated snapshots).
        return models.keys.filter { model.hasPrefix($0 + "-") }.max { $0.count < $1.count }.flatMap { models[$0] }
    }

    /// Parses the "Standard pricing data" table of the official pricing Markdown.
    static func parse(markdown: String) -> OpenAIPricing? {
        let lines = markdown.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("### Standard pricing data") }) else {
            return parse(tableLines: lines)
        }
        let table = lines[(start + 1)...].drop { !$0.hasPrefix("|") }.prefix { $0.hasPrefix("|") }
        return parse(tableLines: Array(table))
    }

    private static func parse(tableLines: [String]) -> OpenAIPricing? {
        let rows = tableLines.filter { $0.hasPrefix("|") }.map {
            $0.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let header = rows.first?.map({ $0.lowercased() }) else { return nil }
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let si = col("short context input"), let sc = col("short context cached input"),
              let so = col("short context output") else { return nil }
        let sw = col("short context cache writes")
        let li = col("long context input"), lc = col("long context cached input")
        let lw = col("long context cache writes"), lo = col("long context output")

        var models: [String: ModelPrice] = [:]
        for row in rows.dropFirst(2) where row.count == header.count {
            func usd(_ i: Int?) -> Double? {
                guard let i else { return nil }
                return Double(row[i].replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""))
            }
            // "gpt-5.5 (<272K context length)" -> "gpt-5.5"
            let name = row[0].replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
            guard let input = usd(si), let output = usd(so) else { continue }
            // A "-" cell means no separate rate: cached input and cache writes fall back to input.
            let short = Rates(input: input, cachedInput: usd(sc) ?? input,
                              cacheWrite: usd(sw) ?? input, output: output)
            let long: Rates
            if let lIn = usd(li), let lOut = usd(lo) {
                long = Rates(input: lIn, cachedInput: usd(lc) ?? lIn, cacheWrite: usd(lw) ?? lIn, output: lOut)
            } else {
                long = short
            }
            models[name] = ModelPrice(short: short, long: long)
        }
        return models.isEmpty ? nil : OpenAIPricing(models: models)
    }

    /// Standard table copied from the official page on 2026-10-03; used until a fetch succeeds.
    static let bundledDate = "2026-10-03"
    static let bundled = parse(markdown: bundledTable)!

    private static let bundledTable = """
| Model | Short context input | Short context cached input | Short context cache writes | Short context output | Long context input | Long context cached input | Long context cache writes | Long context output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| gpt-6-astra | $10.00 | $1.00 | $12.50 | $50.00 | $20.00 | $2.00 | $25.00 | $75.00 |
| gpt-6.1-sol | $2.00 | $0.10 | $2.50 | $10.00 | $4.00 | $0.20 | $5.00 | $15.00 |
| gpt-6-luna | $0.10 | $0.01 | $0.125 | $0.50 | $0.20 | $0.02 | $0.25 | $0.75 |
| gpt-6-sol | $2.00 | $0.20 | $2.50 | $10.00 | $4.00 | $0.40 | $5.00 | $15.00 |
| gpt-5.6-sol | $4.00 | $0.40 | $5.00 | $20.00 | $8.00 | $0.80 | $10.00 | $30.00 |
| gpt-5.6-terra | $2.00 | $0.20 | $2.50 | $12.00 | $4.00 | $0.40 | $5.00 | $18.00 |
| gpt-5.6-luna | $0.20 | $0.02 | $0.25 | $1.20 | $0.40 | $0.04 | $0.50 | $1.80 |
| gpt-5.5 (<272K context length) | $5.00 | $0.50 | - | $30.00 | $10.00 | $1.00 | - | $45.00 |
| gpt-5.5-pro (<272K context length) | $30.00 | - | - | $180.00 | $60.00 | - | - | $270.00 |
| gpt-5.4 (<272K context length) | $2.50 | $0.25 | - | $15.00 | $5.00 | $0.50 | - | $22.50 |
| gpt-5.4-mini | $0.75 | $0.075 | - | $4.50 | - | - | - | - |
| gpt-5.4-nano | $0.20 | $0.02 | - | $1.25 | - | - | - | - |
| gpt-5.4-pro (<272K context length) | $30.00 | - | - | $180.00 | $60.00 | - | - | $270.00 |
| gpt-5.2 | $1.75 | $0.175 | - | $14.00 | - | - | - | - |
| gpt-5.2-pro | $21.00 | - | - | $168.00 | - | - | - | - |
| gpt-5.1 | $1.25 | $0.125 | - | $10.00 | - | - | - | - |
| gpt-5 | $1.25 | $0.125 | - | $10.00 | - | - | - | - |
| gpt-5-mini | $0.25 | $0.025 | - | $2.00 | - | - | - | - |
| gpt-5-nano | $0.05 | $0.005 | - | $0.40 | - | - | - | - |
| gpt-5-pro | $15.00 | - | - | $120.00 | - | - | - | - |
| gpt-4.1 | $2.00 | $0.50 | - | $8.00 | - | - | - | - |
| gpt-4.1-mini | $0.40 | $0.10 | - | $1.60 | - | - | - | - |
| gpt-4.1-nano | $0.10 | $0.025 | - | $0.40 | - | - | - | - |
| gpt-4o | $2.50 | $1.25 | - | $10.00 | - | - | - | - |
| gpt-4o-2024-05-13 | $5.00 | - | - | $15.00 | - | - | - | - |
| gpt-4o-mini | $0.15 | $0.075 | - | $0.60 | - | - | - | - |
| o1 | $15.00 | $7.50 | - | $60.00 | - | - | - | - |
| o1-pro | $150.00 | - | - | $600.00 | - | - | - | - |
| o3-pro | $20.00 | - | - | $80.00 | - | - | - | - |
| o3 | $2.00 | $0.50 | - | $8.00 | - | - | - | - |
| o4-mini | $1.10 | $0.275 | - | $4.40 | - | - | - | - |
| o3-mini | $1.10 | $0.55 | - | $4.40 | - | - | - | - |
| gpt-4-turbo-2024-04-09 | $10.00 | - | - | $30.00 | - | - | - | - |
| gpt-4-0613 | $30.00 | - | - | $60.00 | - | - | - | - |
| gpt-3.5-turbo | $0.50 | - | - | $1.50 | - | - | - | - |
| gpt-3.5-turbo-0125 | $0.50 | - | - | $1.50 | - | - | - | - |
| gpt-3.5-turbo-1106 | $1.00 | - | - | $2.00 | - | - | - | - |
| gpt-3.5-turbo-instruct | $1.50 | - | - | $2.00 | - | - | - | - |
| davinci-002 | $2.00 | - | - | $2.00 | - | - | - | - |
| babbage-002 | $0.40 | - | - | $0.40 | - | - | - | - |
"""
}
