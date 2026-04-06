//
//  VoiceManager.swift
//  MaqkrsTutor
//
//  Core/MLX — Text-to-Speech via AVSpeechSynthesizer
//  Phase 5.5: Audio Output Feature
//
//  Constraints:
//  - All audio output is 100% on-device via AVFoundation — zero cloud TTS
//  - Markdown symbols are stripped before reading aloud
//  - Voice matches the selected target language (BCP-47 code)
//

import Foundation
import AVFoundation
import Observation

// MARK: - Voice Manager

/// Provides on-device text-to-speech for AI message bubbles using `AVSpeechSynthesizer`.
/// Inject as an `@Environment` value in the SwiftUI hierarchy.
///
/// Usage:
/// ```swift
/// @Environment(VoiceManager.self) private var voice
/// voice.speak(text: message.content, language: "en-US")
/// ```
@Observable
final class VoiceManager: NSObject, AVSpeechSynthesizerDelegate {

    // MARK: - Observable State

    /// Whether the synthesizer is currently speaking.
    var isSpeaking: Bool = false

    /// The message ID currently being spoken (used to highlight the active bubble).
    var speakingMessageId: UUID? = nil

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Public API

    /// Reads the given text aloud after stripping markdown formatting.
    ///
    /// - Parameters:
    ///   - text: The raw markdown text to speak.
    ///   - language: A BCP-47 language code (e.g., "en-US", "tr-TR").
    ///   - messageId: Optional message UUID for highlighting the active bubble.
    func speak(text: String, language: String = "en-US", messageId: UUID? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Stop any current speech before starting new
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let cleaned = stripMarkdown(text)
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: "en-US")  // Fallback to English
        utterance.rate = 0.52           // Slightly slower than default — easier for learning
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        speakingMessageId = messageId
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Stops any active speech immediately.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        speakingMessageId = nil
    }

    /// Toggles speak/stop for the given message.
    func toggle(text: String, language: String, messageId: UUID) {
        if isSpeaking && speakingMessageId == messageId {
            stop()
        } else {
            speak(text: text, language: language, messageId: messageId)
        }
    }

    // MARK: - Markdown Stripping

    /// Removes common Markdown symbols so they are not read aloud literally.
    ///
    /// Strips: `#`, `*`, `_`, `` ` ``, `~`, `[`, `]`, `(`, `)`, `>`, `-` (list bullets)
    private func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove code blocks entirely (don't read raw code)
        result = result.replacing(/```[\s\S]*?```/, with: "[code block]")
        result = result.replacing(/`[^`]+`/, with: "")

        // Remove heading markers (multiline: anchored to line start)
        if let headingRegex = try? Regex("^#{1,6}\\s").anchorsMatchLineEndings() {
            result = result.replacing(headingRegex, with: "")
        }

        // Remove bold/italic markers
        result = result.replacing(/[*_]{1,3}([^*_]+)[*_]{1,3}/) { match in
            String(match.output.1)
        }

        // Remove blockquotes (multiline: anchored to line start)
        if let blockquoteRegex = try? Regex("^>\\s").anchorsMatchLineEndings() {
            result = result.replacing(blockquoteRegex, with: "")
        }

        // Remove list bullets (multiline: anchored to line start)
        if let listRegex = try? Regex("^[-*+]\\s").anchorsMatchLineEndings() {
            result = result.replacing(listRegex, with: "")
        }

        // Remove markdown links, keep display text
        result = result.replacing(/\[([^\]]+)\]\([^)]+\)/) { match in
            String(match.output.1)
        }

        // Remove strikethrough
        result = result.replacing(/~~([^~]+)~~/) { match in
            String(match.output.1)
        }

        // Collapse multiple newlines
        result = result.replacing(/\n{3,}/, with: "\n\n")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        speakingMessageId = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        speakingMessageId = nil
    }
}
