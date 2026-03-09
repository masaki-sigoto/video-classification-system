import Foundation
import OSLog
import AppKit
import UniformTypeIdentifiers

// MARK: - LogExporter

/// AuditLog のエクスポート機能を提供するユーティリティ。
///
/// - CSV: RFC 4180 準拠のカンマ区切り形式
/// - JSON: UTF-8 エンコードの JSON 配列
/// - ファイル保存: NSSavePanel でユーザーが保存先を選択
enum LogExporter {

    // MARK: - CSV エクスポート

    /// AuditLog の配列を CSV 文字列に変換する。
    ///
    /// ヘッダー行: `logID,at,level,eventType,entityID,messageRedacted`
    ///
    /// - Parameter logs: エクスポートする AuditLog の配列
    /// - Returns: RFC 4180 準拠の CSV 文字列（改行コード LF）
    static func exportToCSV(logs: [AuditLog]) -> String {
        var lines: [String] = []

        // ヘッダー行
        lines.append("logID,at,level,eventType,entityID,messageRedacted")

        // ISO 8601 日時フォーマッタ
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        // データ行
        for log in logs {
            let fields: [String] = [
                csvEscape(log.logID),
                csvEscape(dateFormatter.string(from: log.at)),
                csvEscape(log.level.rawValue),
                csvEscape(log.eventType),
                csvEscape(log.entityID ?? ""),
                csvEscape(log.messageRedacted)
            ]
            lines.append(fields.joined(separator: ","))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON エクスポート

    /// AuditLog の配列を JSON Data に変換する。
    ///
    /// - Parameter logs: エクスポートする AuditLog の配列
    /// - Returns: UTF-8 エンコードの JSON Data
    /// - Throws: JSON シリアライズに失敗した場合
    static func exportToJSON(logs: [AuditLog]) throws -> Data {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        let jsonArray: [[String: Any]] = logs.map { log in
            var dict: [String: Any] = [
                "logID": log.logID,
                "at": dateFormatter.string(from: log.at),
                "level": log.level.rawValue,
                "eventType": log.eventType,
                "messageRedacted": log.messageRedacted
            ]
            if let entityID = log.entityID {
                dict["entityID"] = entityID
            }
            return dict
        }

        let data = try JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys])
        SVLogger.general.info("LogExporter: JSON エクスポート完了 count=\(logs.count)")
        return data
    }

    // MARK: - ファイル保存

    /// データをユーザーが選択した場所にファイルとして保存する。
    ///
    /// `NSSavePanel` でユーザーに保存先を選択させる。
    /// メインスレッドから呼ぶこと（NSSavePanel 要件）。
    ///
    /// - Parameters:
    ///   - data: 書き込む Data
    ///   - filename: デフォルトのファイル名（例: "audit-log.csv"）
    /// - Returns: 保存したファイルの URL
    /// - Throws: `LogExportError.userCancelled` または `LogExportError.writeFailed`
    @MainActor
    static func saveToFile(data: Data, filename: String) throws -> URL {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        // 拡張子からコンテンツタイプを設定
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "csv" {
            panel.allowedContentTypes = [.commaSeparatedText]
        } else if ext == "json" {
            panel.allowedContentTypes = [.json]
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            SVLogger.general.info("LogExporter: ユーザーがキャンセルしました")
            throw LogExportError.userCancelled
        }

        do {
            try data.write(to: url, options: .atomic)
            SVLogger.general.info("LogExporter: ファイル保存完了 path=\(url.path, privacy: .sensitive)")
            return url
        } catch {
            SVLogger.general.error("LogExporter: ファイル書き込み失敗 \(error.localizedDescription, privacy: .public)")
            throw LogExportError.writeFailed(url: url, underlying: error)
        }
    }

    // MARK: - Private helpers

    /// CSV フィールドをエスケープする（RFC 4180 準拠）。
    ///
    /// カンマ・ダブルクォート・改行が含まれる場合はダブルクォートで囲み、
    /// 内部のダブルクォートは `""` に変換する。
    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

// MARK: - LogExportError

/// `LogExporter` が送出するエラー
enum LogExportError: LocalizedError {
    /// ユーザーが NSSavePanel でキャンセルした
    case userCancelled
    /// ファイルの書き込みに失敗した
    case writeFailed(url: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "エクスポートがキャンセルされました。"
        case .writeFailed(let url, let underlying):
            return "ファイルの書き込みに失敗しました: \(url.lastPathComponent) — \(underlying.localizedDescription)"
        }
    }
}
