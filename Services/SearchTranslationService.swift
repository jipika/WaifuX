import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

// MARK: - 翻译桥接器（macOS 14+ 可用，翻译 macOS 15+）

/// 搜索翻译桥接器：语言检测 macOS 14+，翻译 macOS 15+
///
/// 明确隔离到主 actor，确保所有 @Published 都只从主线程发布。
/// `.translationTask` 的执行入口保持 nonisolated，只在需要读写 UI 状态时切回 MainActor。
@MainActor
final class SearchTranslationBridge: ObservableObject, @unchecked Sendable {
    @Published private(set) var isChineseDetected = false
    @Published private(set) var translatedText: String?
    @Published private(set) var isTranslating = false
    @Published private(set) var translationDismissed = false
    @Published private(set) var translationCompleted = false

    /// 记录已翻译对应的原始中文文本，用于判断当前文本是否已翻译
    private(set) var translatedSourceText: String?

    private var debounceTask: Task<Void, Never>?
    private var translationCache: [String: String] = [:]
    private let maxCacheSize = 100
    private var pendingText: String?

    // MARK: - 语言检测（macOS 14+）

    @MainActor
    func detectLanguage(for text: String) {
        debounceTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isChineseDetected = false
            translatedText = nil
            translationDismissed = false
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString(trimmed)
            let detected = recognizer.dominantLanguage?.rawValue.hasPrefix("zh") == true

            await MainActor.run {
                self.isChineseDetected = detected
                if !detected { self.translatedText = nil }
                self.translationDismissed = false
            }
        }
    }

    // MARK: - 缓存查询（macOS 15+，供 View 层调用）

    /// 查询翻译缓存，命中则直接设置结果并返回 true
    @MainActor
    func checkCache(for text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = translationCache[trimmed] {
            AppLogger.debug(.wallpaper, "[翻译] 命中缓存: \(trimmed) → \(cached)")
            translatedText = cached
            translatedSourceText = trimmed
            translationCompleted.toggle()
            return true
        }
        return false
    }

    // MARK: - 准备翻译（macOS 15+，供 View 层调用）

    /// 设置 pendingText 和 isTranslating，由 View 层设置 config 触发 .translationTask
    @MainActor
    func prepareForTranslation(_ text: String) {
        pendingText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isTranslating = true
    }

    /// 翻译请求 ID，每次需要翻译时递增，子 View 观察后调用 config.invalidate()
    @Published private(set) var translationRequestID: Int = 0

    /// 通知子 View 需要触发翻译
    @MainActor
    func triggerTranslation() {
        translationRequestID += 1
    }

    // MARK: - 翻译执行（由 .translationTask 闭包调用）

    /// nonisolated：避免 session 跨隔离边界。
    /// UI 状态通过 MainActor.run 更新。
    @available(macOS 15.0, *)
    nonisolated func performTranslation(session: TranslationSession) async {
        guard let text = await MainActor.run(body: { self.pendingText }) else {
            AppLogger.debug(.wallpaper, "[翻译] performTranslation: pendingText 为空，跳过")
            await MainActor.run {
                self.translatedSourceText = nil
                self.isTranslating = false
                self.translationCompleted.toggle()
            }
            return
        }
        AppLogger.debug(.wallpaper, "[翻译] performTranslation: 开始翻译 '\(text)'")

        do {
            let response = try await session.translate(text)
            let result = response.targetText

            AppLogger.debug(.wallpaper, "[翻译] 翻译成功: '\(text)' → '\(result)'")
            await MainActor.run {
                self.translationCache[text] = result
                if self.translationCache.count > self.maxCacheSize {
                    if let oldestKey = self.translationCache.keys.first {
                        self.translationCache.removeValue(forKey: oldestKey)
                    }
                }
                self.translatedText = result
                self.translatedSourceText = text
                self.isTranslating = false
                self.pendingText = nil
                self.translationCompleted.toggle()
                AppLogger.debug(.wallpaper, "[翻译] 已设置 translatedText='\(result)'")
            }
        } catch {
            AppLogger.debug(.wallpaper, "[翻译] 翻译失败: \(error)")
            await MainActor.run {
                self.translatedText = nil
                self.translatedSourceText = nil
                self.isTranslating = false
                self.pendingText = nil
                self.translationCompleted.toggle()
            }
        }
    }

    // MARK: - 操作

    @MainActor
    func dismiss() {
        translationDismissed = true
        translatedText = nil
        translatedSourceText = nil
    }

    /// 清除翻译结果（搜索文本变化时调用，确保下次回车重新翻译）
    @MainActor
    func clearTranslation() {
        translatedText = nil
        translatedSourceText = nil
        isTranslating = false
    }

    @MainActor
    func reset() {
        debounceTask?.cancel()
        isChineseDetected = false
        translatedText = nil
        translatedSourceText = nil
        isTranslating = false
        translationDismissed = false
        pendingText = nil
    }

    /// 同步检测文本是否为中文（用于 submitSearch，不依赖 debounce 结果）
    nonisolated func isChinese(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage?.rawValue.hasPrefix("zh") == true
    }

    @MainActor
    func effectiveQuery(for originalText: String) -> String {
        if let translated = translatedText, !translationDismissed {
            return translated
        }
        return originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 翻译任务宿主 View（macOS 15+）

/// 持有 @State config，通过 invalidate() 触发重翻译（Apple 推荐方式）
/// 子 View 观察 bridge.translationRequestID 变化后调用 config.invalidate()
@available(macOS 15.0, *)
struct TranslationTaskHost<Content: View>: View {
    let bridge: SearchTranslationBridge
    @ViewBuilder let content: () -> Content
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        content()
            .translationTask(config) { session in
                await bridge.performTranslation(session: session)
            }
            .onChange(of: bridge.translationRequestID) { _, _ in
                if config == nil {
                    config = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "zh"),
                        target: Locale.Language(identifier: "en")
                    )
                } else {
                    config?.invalidate()
                }
            }
    }
}
