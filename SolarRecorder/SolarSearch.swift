// SolarRecorder/SolarRecorder/SolarSearch.swift
// Изолированный модуль локального поиска v1.
// Поиск по: name, transcript, translation, summary
// Не изменяет стабильную базу — только добавляется в проект.

import Foundation
import SwiftUI

// ═══════════════════════════════════════════════════════
// MARK: - SolarSearchService
// ═══════════════════════════════════════════════════════

final class SolarSearchService {

    // MARK: - Public API

    /// Фильтрует записи по поисковому запросу.
    /// Пустой запрос → возвращает все записи без изменений.
    static func filter(recordings: [Recording], query: String) -> [Recording] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return recordings }

        return recordings.filter { matches($0, query: q) }
    }

    // MARK: - Match logic

    private static func matches(_ recording: Recording, query: String) -> Bool {
        // name
        if recording.name.localizedCaseInsensitiveContains(query) { return true }

        // transcript
        if let t = recording.transcript,
           t.localizedCaseInsensitiveContains(query) { return true }

        // translation
        if let t = recording.translation,
           t.localizedCaseInsensitiveContains(query) { return true }

        // summary
        if let s = recording.summary,
           s.localizedCaseInsensitiveContains(query) { return true }

        // formattedDate — поиск по дате "13.05.2026"
        if recording.formattedDate.localizedCaseInsensitiveContains(query) { return true }

        return false
    }

    // MARK: - Search stats

    /// Возвращает количество совпадений по полям для отладки.
    static func matchStats(_ recording: Recording, query: String) -> SearchMatchStats {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchMatchStats() }

        return SearchMatchStats(
            inName:        recording.name.localizedCaseInsensitiveContains(q),
            inTranscript:  recording.transcript?.localizedCaseInsensitiveContains(q) ?? false,
            inTranslation: recording.translation?.localizedCaseInsensitiveContains(q) ?? false,
            inSummary:     recording.summary?.localizedCaseInsensitiveContains(q) ?? false
        )
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - SearchMatchStats
// ═══════════════════════════════════════════════════════

struct SearchMatchStats {
    var inName:        Bool = false
    var inTranscript:  Bool = false
    var inTranslation: Bool = false
    var inSummary:     Bool = false

    var matchedFields: [String] {
        var fields: [String] = []
        if inName        { fields.append("Название") }
        if inTranscript  { fields.append("Текст") }
        if inTranslation { fields.append("Перевод") }
        if inSummary     { fields.append("Резюме") }
        return fields
    }

    var hasMatch: Bool { inName || inTranscript || inTranslation || inSummary }
}

// ═══════════════════════════════════════════════════════
// MARK: - SearchMatchBadge  (UI компонент)
// ═══════════════════════════════════════════════════════
// Показывает где именно найдено совпадение

struct SearchMatchBadge: View {
    let stats: SearchMatchStats

    var body: some View {
        if stats.hasMatch && !stats.matchedFields.isEmpty {
            HStack(spacing: 4) {
                ForEach(stats.matchedFields, id: \.self) { field in
                    Text(field)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.1))
                        )
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - SearchEmptyView  (UI компонент)
// ═══════════════════════════════════════════════════════

struct SearchEmptyView: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.gray.opacity(0.4))
            Text("Ничего не найдено")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.gray)
            Text("По запросу «\(query)» записей не найдено")
                .font(.system(size: 13))
                .foregroundColor(.gray.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }
}
