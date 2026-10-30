import Foundation
import Speech
import AVFAudio

// iOS 26's DictationTranscriber is available on devices where the newer
// SpeechTranscriber model is not. Keep audio in the app's temporary directory
// only until transcription completes.
@objc(BBLocalDictation)
final class BBLocalDictation: NSObject {
    @objc static func transcribeFile(_ path: String,
                                    completion: @escaping (NSString?, NSString?) -> Void) {
        Task { @MainActor in
            let url = URL(fileURLWithPath: path)
            defer { try? FileManager.default.removeItem(at: url) }
            guard #available(iOS 26.0, *) else {
                completion(nil, "iOS 26 required")
                return
            }
            do {
                guard let locale = await DictationTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: "zh-CN")) else {
                    completion(nil, "zh-CN unsupported")
                    return
                }
                let transcriber = DictationTranscriber(locale: locale, preset: .shortDictation)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let resultTask = Task { () throws -> String in
                    var latest = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if !text.isEmpty { latest = text }
                    }
                    return latest
                }
                do {
                    let audio = try AVAudioFile(forReading: url)
                    if let last = try await analyzer.analyzeSequence(from: audio) {
                        try await analyzer.finalizeAndFinish(through: last)
                    } else {
                        await analyzer.cancelAndFinishNow()
                    }
                    let text = try await resultTask.value
                    completion(text.isEmpty ? nil : text as NSString,
                               text.isEmpty ? "no speech recognized" : nil)
                } catch {
                    await analyzer.cancelAndFinishNow()
                    resultTask.cancel()
                    throw error
                }
            } catch {
                let failure = error as NSError
                completion(nil, "\(failure.domain):\(failure.code)" as NSString)
            }
        }
    }
}
