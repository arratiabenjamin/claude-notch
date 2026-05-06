// SessionPreview.swift
// Lightweight preview snapshot of a session's most recent activity, used
// by the satellite hover bubble in OrbView.
//
// Distinct from TranscriptSummarizer's output:
//   • Summarizer produces ONE short sentence for TTS / notification body.
//   • Preview keeps the most recent user prompt and assistant text RAW,
//     truncated, so the hover bubble can show "what's happening now"
//     verbatim — no model in the loop, no risk of hallucination.
import Foundation

struct SessionPreview: Equatable, Sendable {
    /// Most recent user prompt in the transcript, truncated. Nil if none was
    /// found in the inspected tail of the file.
    let lastUserPrompt: String?
    /// Most recent assistant text response (after any tool calls), truncated.
    /// Nil if the assistant hasn't produced a text reply yet.
    let lastAssistantText: String?

    static let empty = SessionPreview(
        lastUserPrompt: nil,
        lastAssistantText: nil
    )

    /// True when both fields are nil — caller can decide to show a placeholder
    /// like "Sin actividad reciente" instead of an empty bubble.
    var isEmpty: Bool {
        (lastUserPrompt == nil || lastUserPrompt?.isEmpty == true) &&
        (lastAssistantText == nil || lastAssistantText?.isEmpty == true)
    }
}
