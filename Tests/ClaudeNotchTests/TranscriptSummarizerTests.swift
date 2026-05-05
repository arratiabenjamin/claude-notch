// TranscriptSummarizerTests.swift
// Cover the pure-logic helpers inside TranscriptSummarizer:
//   - extractClaudeSummary(rawJSONL:) — the SUMMARY: line scanner that
//     short-circuits Foundation Models when Claude self-summarized.
//   - sanitizeAIOutput(_:) — strips actor labels and meta preambles the
//     on-device model adds despite prompt instructions.
//
// We don't touch summarize() itself here — it's @MainActor async and pulls
// in Foundation Models at runtime; integration testing of that path is a
// separate concern.
import XCTest
@testable import ClaudeNotch

@MainActor
final class TranscriptSummarizerTests: XCTestCase {

    // MARK: - extractClaudeSummary

    /// Build a minimal JSONL transcript where the assistant's last message
    /// contains `text` as its single text item.
    private func transcript(lastAssistantText: String) -> String {
        let payload: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": lastAssistantText]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return String(data: data, encoding: .utf8)!
    }

    func testExtractsPlainSummaryLine() {
        let body = """
        Listé los archivos del directorio.

        SUMMARY: Listó archivos en /Users/benja y mostró estructura.
        """
        let result = TranscriptSummarizer.extractClaudeSummary(
            rawJSONL: transcript(lastAssistantText: body)
        )
        XCTAssertEqual(result, "Listó archivos en /Users/benja y mostró estructura.")
    }

    func testIsCaseInsensitiveOnMarker() {
        let body = "summary: Configuró las migraciones de Supabase."
        let result = TranscriptSummarizer.extractClaudeSummary(
            rawJSONL: transcript(lastAssistantText: body)
        )
        XCTAssertEqual(result, "Configuró las migraciones de Supabase.")
    }

    func testStripsBoldMarkdownAroundMarker() {
        let body = "**SUMMARY:** Refactorizó el módulo de auth."
        let result = TranscriptSummarizer.extractClaudeSummary(
            rawJSONL: transcript(lastAssistantText: body)
        )
        XCTAssertEqual(result, "Refactorizó el módulo de auth.")
    }

    func testStripsBracketsAroundMarker() {
        let body = "[SUMMARY]: Agregó tests para el slot manager."
        let result = TranscriptSummarizer.extractClaudeSummary(
            rawJSONL: transcript(lastAssistantText: body)
        )
        XCTAssertEqual(result, "Agregó tests para el slot manager.")
    }

    func testReadsSummaryOnNextLineWhenMarkerStandsAlone() {
        let body = """
        Trabajó en varias cosas.

        SUMMARY:

        Investigó el bug del hover monitor.
        """
        let result = TranscriptSummarizer.extractClaudeSummary(
            rawJSONL: transcript(lastAssistantText: body)
        )
        XCTAssertEqual(result, "Investigó el bug del hover monitor.")
    }

    func testReturnsNilWhenNoSummary() {
        let body = "Hizo varias cosas pero no dejó marker."
        let result = TranscriptSummarizer.extractClaudeSummary(
            rawJSONL: transcript(lastAssistantText: body)
        )
        XCTAssertNil(result)
    }

    func testPicksLastAssistantMessage() {
        // Two assistant messages: the FIRST has a SUMMARY mention but it's
        // earlier in the conversation; the LAST is what we care about.
        let first = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"En un mensaje anterior dije: SUMMARY: nope"}]}}
        """
        let last = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Cerró sesión.\\n\\nSUMMARY: Cerró sesión limpia."}]}}
        """
        let combined = first + "\n" + last
        let result = TranscriptSummarizer.extractClaudeSummary(rawJSONL: combined)
        XCTAssertEqual(result, "Cerró sesión limpia.")
    }

    func testIgnoresUserMessagesWithSummaryWord() {
        // User messages shouldn't be considered — only assistant text.
        // The assistant's SUMMARY line lives at the start of its own line.
        let userLine = """
        {"type":"user","message":{"role":"user","content":"SUMMARY: this is the user typing"}}
        """
        let assistantLine = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Respondió.\\nSUMMARY: Respondió a la pregunta del usuario."}]}}
        """
        let combined = userLine + "\n" + assistantLine
        let result = TranscriptSummarizer.extractClaudeSummary(rawJSONL: combined)
        XCTAssertEqual(result, "Respondió a la pregunta del usuario.")
    }

    func testHandlesEmptyTranscript() {
        XCTAssertNil(TranscriptSummarizer.extractClaudeSummary(rawJSONL: ""))
    }

    // MARK: - sanitizeAIOutput

    func testStripsLeadingActorLabels() {
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("El asistente generó código para listar archivos."),
            "Generó código para listar archivos."
        )
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("Claude refactorizó el módulo."),
            "Refactorizó el módulo."
        )
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("La sesión terminó después de varios cambios."),
            "Terminó después de varios cambios."
        )
    }

    func testStripsMetaPreambles() {
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("Resumen: Hizo tests."),
            "Hizo tests."
        )
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("Aquí está el resumen: Hizo tests."),
            "Hizo tests."
        )
    }

    func testStripsSurroundingQuotes() {
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("\"Refactorizó el módulo.\""),
            "Refactorizó el módulo."
        )
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("“Refactorizó el módulo.”"),
            "Refactorizó el módulo."
        )
    }

    func testLeavesCleanOutputAlone() {
        let clean = "Refactorizó el módulo de auth y agregó tres tests."
        XCTAssertEqual(TranscriptSummarizer.sanitizeAIOutput(clean), clean)
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(
            TranscriptSummarizer.sanitizeAIOutput("   Refactorizó.   "),
            "Refactorizó."
        )
    }
}
