// SolarRecorder/SolarRecorder/SolarImport.swift
// Изолированный модуль импорта аудиофайлов v1.
// Поддерживает: wav, m4a, mp3
// Не изменяет стабильную базу — только добавляется в проект.

import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════
// MARK: - ImportResult
// ═══════════════════════════════════════════════════════

enum ImportResult {
    case success(URL)
    case unsupportedFormat(String)
    case conversionFailed(String)
    case copyFailed(String)
    case duplicate(URL)
}

// ═══════════════════════════════════════════════════════
// MARK: - SolarImportService
// ═══════════════════════════════════════════════════════

final class SolarImportService: ObservableObject {

    @Published var isImporting: Bool = false
    @Published var lastError: String? = nil

    // Поддерживаемые форматы
    static let supportedTypes: [UTType] = [
        .wav,
        UTType(filenameExtension: "m4a") ?? .audio,
        UTType(filenameExtension: "mp3") ?? .audio,
        .audio
    ]

    private var storageFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("SolarRecords", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                  withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Import entry point

    func importFile(from sourceURL: URL, completion: @escaping (ImportResult) -> Void) {
        isImporting = true
        lastError = nil

        Task {
            let result = await performImport(from: sourceURL)
            await MainActor.run {
                self.isImporting = false
                if case .copyFailed(let msg) = result { self.lastError = msg }
                if case .conversionFailed(let msg) = result { self.lastError = msg }
                if case .unsupportedFormat(let ext) = result {
                    self.lastError = "Формат .\(ext) не поддерживается"
                }
                completion(result)
            }
        }
    }

    // MARK: - Core import logic

    private func performImport(from sourceURL: URL) async -> ImportResult {
        let ext = sourceURL.pathExtension.lowercased()

        // Проверяем формат
        guard ["wav", "m4a", "mp3", "aac", "aiff", "caf"].contains(ext) else {
            return .unsupportedFormat(ext)
        }

        let destName = makeDestinationName()

        // WAV — копируем напрямую
        if ext == "wav" {
            return copyFile(from: sourceURL, destName: destName + ".wav")
        }

        // m4a / mp3 / другие — конвертируем в WAV
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(destName + ".wav")

        do {
            try await convertToWAV(from: sourceURL, to: tempWAV)
            let result = copyFile(from: tempWAV, destName: destName + ".wav")
            try? FileManager.default.removeItem(at: tempWAV)
            return result
        } catch {
            try? FileManager.default.removeItem(at: tempWAV)
            return .conversionFailed(error.localizedDescription)
        }
    }

    // MARK: - Copy

    private func copyFile(from src: URL, destName: String) -> ImportResult {
        let dest = storageFolder.appendingPathComponent(destName)

        // Проверка дубликата
        if FileManager.default.fileExists(atPath: dest.path) {
            return .duplicate(dest)
        }

        // Нужен security scope для picker-файлов
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }

        do {
            try FileManager.default.copyItem(at: src, to: dest)
            return .success(dest)
        } catch {
            return .copyFailed(error.localizedDescription)
        }
    }

    // MARK: - Conversion (m4a/mp3 → WAV PCM 16kHz mono)

    private func convertToWAV(from src: URL, to dest: URL) async throws {
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }

        let asset = AVURLAsset(url: src)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ImportError.conversionUnsupported
        }

        // Пробуем через AVAssetExportSession → линейный PCM
        guard let linearSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ImportError.conversionUnsupported
        }
        _ = exportSession // избегаем warning

        // Используем AVAudioConverter для надёжной конвертации
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: src)
        } catch {
            throw ImportError.cannotReadSource
        }

        // Целевой формат: 16kHz, mono, Int16 PCM (совместим с Whisper)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw ImportError.formatError
        }

        guard let converter = AVAudioConverter(
            from: sourceFile.processingFormat,
            to: targetFormat
        ) else {
            throw ImportError.conversionUnsupported
        }

        let destFile: AVAudioFile
        do {
            destFile = try AVAudioFile(
                forWriting: dest,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw ImportError.cannotWriteDest
        }

        let inputBufferSize: AVAudioFrameCount = 4096
        let outputBufferSize: AVAudioFrameCount = AVAudioFrameCount(
            Double(inputBufferSize) * targetFormat.sampleRate / sourceFile.processingFormat.sampleRate
        ) + 1

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputBufferSize
        ) else {
            throw ImportError.formatError
        }

        var reachedEnd = false

        while !reachedEnd {
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFile.processingFormat,
                    frameCapacity: inputBufferSize
                ) else {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try sourceFile.read(into: inputBuffer)
                    if inputBuffer.frameLength == 0 {
                        reachedEnd = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let error = error { throw error }

            if outputBuffer.frameLength > 0 {
                try destFile.write(from: outputBuffer)
            }

            if status == .endOfStream || reachedEnd { break }
        }
    }

    // MARK: - Safe filename

    private func makeDestinationName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "imported_\(f.string(from: Date()))_ios_standard"
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - ImportError
// ═══════════════════════════════════════════════════════

enum ImportError: Error, LocalizedError {
    case conversionUnsupported
    case cannotReadSource
    case cannotWriteDest
    case formatError

    var errorDescription: String? {
        switch self {
        case .conversionUnsupported: return "Конвертация не поддерживается"
        case .cannotReadSource:      return "Не удалось прочитать файл"
        case .cannotWriteDest:       return "Не удалось записать файл"
        case .formatError:           return "Ошибка аудио формата"
        }
    }
}

// ═══════════════════════════════════════════════════════
// MARK: - ImportButton  (UI компонент)
// ═══════════════════════════════════════════════════════

struct ImportButton: View {
    @StateObject private var service = SolarImportService()
    @State private var showPicker    = false
    @State private var showAlert     = false
    @State private var alertMessage  = ""

    let onImported: (URL) -> Void

    var body: some View {
        Button {
            showPicker = true
        } label: {
            Label("Импорт", systemImage: "square.and.arrow.down")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .disabled(service.isImporting)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: SolarImportService.supportedTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePickerResult(result)
        }
        .alert("Импорт", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .overlay {
            if service.isImporting {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
            }
        }
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertMessage = error.localizedDescription
            showAlert = true
        case .success(let urls):
            guard let url = urls.first else { return }
            service.importFile(from: url) { importResult in
                switch importResult {
                case .success(let destURL):
                    onImported(destURL)
                case .duplicate(let destURL):
                    // Файл уже есть — просто открываем
                    onImported(destURL)
                case .unsupportedFormat(let ext):
                    alertMessage = "Формат .\(ext) не поддерживается.\nИспользуйте: WAV, M4A, MP3"
                    showAlert = true
                case .conversionFailed(let msg):
                    alertMessage = "Ошибка конвертации: \(msg)"
                    showAlert = true
                case .copyFailed(let msg):
                    alertMessage = "Ошибка копирования: \(msg)"
                    showAlert = true
                }
            }
        }
    }
}
