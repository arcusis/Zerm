import Foundation
import Testing
@testable import Zerm

/// Speaker attribution, paragraphs and every export format, with Hebrew and mixed-direction text.
struct FileTranscriptExportTests {

    // MARK: - Attribution and paragraphs

    @Test func speakersAreNumberedInTheOrderTheyFirstSpeak() {
        let transcript = FileTranscript(
            sourceFileName: "call.wav",
            duration: 8,
            modelName: "Model",
            languageCode: "en",
            speakerStatus: .identified,
            segments: [
                TranscriptSegment(start: 0, end: 2, text: "one two three", speakerIndex: 7),
                TranscriptSegment(start: 2, end: 4, text: "four five six", speakerIndex: 3),
                TranscriptSegment(start: 4, end: 6, text: "seven", speakerIndex: 7)
            ]
        )

        #expect(transcript.segments.map(\.speakerIndex) == [0, 1, 0])
        #expect(transcript.speakers.map(\.index) == [0, 1])
    }

    @Test func segmentsWithoutSpeakersHaveNoLabels() {
        let transcript = FileTranscript(
            sourceFileName: "call.wav",
            duration: 4,
            modelName: "Model",
            languageCode: "en",
            speakerStatus: .failed,
            segments: [TranscriptSegment(start: 0, end: 4, text: "hello there")]
        )

        #expect(transcript.speakers.isEmpty)
        #expect(transcript.plainText == "hello there")
    }

    @Test func adjacentSegmentsOfOneSpeakerMergeIntoParagraphs() {
        let transcript = FileTranscript(
            sourceFileName: "talk.wav",
            duration: 200,
            modelName: "Model",
            languageCode: "en",
            speakerStatus: .identified,
            segments: [
                TranscriptSegment(start: 0, end: 30, text: "first", speakerIndex: 0),
                TranscriptSegment(start: 30, end: 60, text: "second", speakerIndex: 0),
                TranscriptSegment(start: 60, end: 70, text: "reply", speakerIndex: 1),
                TranscriptSegment(start: 70, end: 100, text: "third", speakerIndex: 0),
                TranscriptSegment(start: 100, end: 130, text: "   ", speakerIndex: 0),
                TranscriptSegment(start: 130, end: 165, text: "fourth", speakerIndex: 0),
                TranscriptSegment(start: 165, end: 195, text: "fifth", speakerIndex: 0)
            ]
        )

        let paragraphs = transcript.paragraphs
        // "fourth" would stretch the third paragraph past 90 seconds, so it starts a new one.
        #expect(paragraphs.map(\.text) == ["first second", "reply", "third", "fourth fifth"])
        #expect(paragraphs.map(\.speakerIndex) == [0, 1, 0, 0])
        #expect(paragraphs.map(\.start) == [0, 60, 70, 130])
        #expect(paragraphs.map(\.id) == [0, 1, 2, 3])
    }

    @Test func renamingASpeakerAndClearingTheNameRestoresTheDefault() {
        var transcript = Self.interview
        #expect(transcript.name(forSpeaker: 0) == "Dana")

        transcript.rename(speaker: 0, to: "   ")
        #expect(transcript.name(forSpeaker: 0) == FileTranscript.defaultName(forSpeaker: 0))
        #expect(FileTranscript.defaultName(forSpeaker: 2).contains("3"))

        transcript.rename(speaker: 9, to: "Nobody")
        #expect(transcript.speakers.count == 2)
    }

    @Test func sidecarRoundTripsSpeakerNames() throws {
        let data = try JSONEncoder().encode(Self.interview)
        let decoded = try JSONDecoder().decode(FileTranscript.self, from: data)

        #expect(decoded == Self.interview)
        #expect(decoded.name(forSpeaker: 1) == "דוד")
    }

    // MARK: - Formats

    @Test func plainTextLabelsEachParagraph() {
        #expect(Self.interview.plainText == """
        Dana: Hello and welcome to the show.

        דוד: שלום, תודה שהזמנת אותי. It is great to be here.
        """)
    }

    @Test func textExport() {
        #expect(FileTranscriptExporter.export(Self.interview, as: .text) == """
        [0:00] Dana: Hello and welcome to the show.

        [0:04] דוד: שלום, תודה שהזמנת אותי. It is great to be here.

        """)
    }

    @Test func markdownExport() {
        #expect(FileTranscriptExporter.export(Self.interview, as: .markdown) == """
        # interview.m4a

        **Dana** · 0:00

        Hello and welcome to the show.

        **דוד** · 0:04

        שלום, תודה שהזמנת אותי. It is great to be here.

        """)
    }

    @Test func srtExport() {
        #expect(FileTranscriptExporter.export(Self.interview, as: .srt) == """
        1
        00:00:00,000 --> 00:00:04,000
        Dana: Hello and welcome to the show.

        2
        00:00:04,000 --> 00:00:09,500
        דוד: שלום, תודה שהזמנת אותי.

        3
        00:00:09,500 --> 00:00:12,000
        דוד: \u{2068}It is great to be here.\u{2069}

        """)
    }

    @Test func vttExport() {
        #expect(FileTranscriptExporter.export(Self.interview, as: .vtt) == """
        WEBVTT

        00:00:00.000 --> 00:00:04.000
        Dana: Hello and welcome to the show.

        00:00:04.000 --> 00:00:09.500
        דוד: שלום, תודה שהזמנת אותי.

        00:00:09.500 --> 00:00:12.000
        דוד: \u{2068}It is great to be here.\u{2069}

        """)
    }

    @Test func jsonExport() {
        #expect(FileTranscriptExporter.export(Self.interview, as: .json) == """
        {
          "duration" : 12,
          "language" : "he",
          "model" : "Whisper Large v3 Turbo",
          "segments" : [
            {
              "end" : 4,
              "speaker" : "Dana",
              "start" : 0,
              "text" : "Hello and welcome to the show."
            },
            {
              "end" : 9.5,
              "speaker" : "דוד",
              "start" : 4,
              "text" : "שלום, תודה שהזמנת אותי."
            },
            {
              "end" : 12,
              "speaker" : "דוד",
              "start" : 9.5,
              "text" : "It is great to be here."
            }
          ],
          "source" : "interview.m4a",
          "speakers" : [
            "Dana",
            "דוד"
          ]
        }

        """)
    }

    @Test func exportsWithoutSpeakersCarryNoLabels() {
        let transcript = FileTranscript(
            sourceFileName: "memo.m4a",
            duration: 3,
            modelName: "Model",
            languageCode: "he",
            speakerStatus: .notRequested,
            segments: [TranscriptSegment(start: 0.25, end: 3, text: "שלום לכולם.")]
        )

        #expect(FileTranscriptExporter.export(transcript, as: .text) == "[0:00] שלום לכולם.\n")
        #expect(FileTranscriptExporter.export(transcript, as: .srt) == "1\n00:00:00,250 --> 00:00:03,000\nשלום לכולם.\n")
        #expect(!FileTranscriptExporter.export(transcript, as: .json).contains("\"speaker\""))
    }

    // MARK: - Right-to-left safety

    @Test func sameDirectionLinesGetNoInvisibleCharacters() {
        for format in [FileTranscriptExporter.Format.text, .markdown, .json] {
            let output = FileTranscriptExporter.export(Self.interview, as: format)
            #expect(!output.unicodeScalars.contains { (0x200E...0x200F).contains($0.value) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })
        }
    }

    @Test func labelIsolatesTextRunningTheOtherWay() {
        #expect(BidiText.labelled("Speaker 1", "שלום.") == "Speaker 1: \u{2068}שלום.\u{2069}")
        #expect(BidiText.labelled("דובר 1", "Hello.") == "דובר 1: \u{2068}Hello.\u{2069}")
        #expect(BidiText.labelled("דובר 1", "שלום.") == "דובר 1: שלום.")
        #expect(BidiText.labelled("Speaker 1", "42") == "Speaker 1: 42")
        #expect(BidiText.isRightToLeft("  12, שלום") == true)
        #expect(BidiText.isRightToLeft("(hello)") == false)
        #expect(BidiText.isRightToLeft("123") == nil)
    }

    // MARK: - Subtitle cues

    @Test func subtitleTimestampsUseEachFormatsSeparator() {
        #expect(FileTranscriptExporter.subtitleTime(1, separator: ",") == "00:00:01,000")
        #expect(FileTranscriptExporter.subtitleTime(1, separator: ".") == "00:00:01.000")
        #expect(FileTranscriptExporter.subtitleTime(3723.4567, separator: ",") == "01:02:03,457")
        #expect(FileTranscriptExporter.subtitleTime(-2, separator: ".") == "00:00:00.000")
    }

    @Test func longSegmentsSplitIntoShortTwoLineCues() {
        let words = (1...60).map { "word\($0)" }
        var transcript = FileTranscript(
            sourceFileName: "lecture.wav",
            duration: 30,
            modelName: "Model",
            languageCode: "en",
            speakerStatus: .identified,
            segments: [TranscriptSegment(start: 0, end: 30, text: words.joined(separator: " "), speakerIndex: 0)]
        )
        transcript.rename(speaker: 0, to: "Prof")

        let cues = FileTranscriptExporter.cues(for: transcript)

        #expect(cues.count > 4)
        for cue in cues {
            #expect(cue.end - cue.start <= FileTranscriptExporter.maximumCueDuration + 0.0001)
            #expect(cue.end > cue.start)
            #expect((1...2).contains(cue.lines.count))
            #expect(cue.lines.allSatisfy { $0.count <= FileTranscriptExporter.maximumLineLength })
            #expect(cue.lines[0].hasPrefix("Prof: "))
        }
        let spoken = cues.flatMap { cue in
            cue.lines.joined(separator: " ").split(separator: " ").map(String.init).filter { $0 != "Prof:" }
        }
        #expect(spoken == words)
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
        #expect(cues.first?.start == 0)
        #expect(abs((cues.last?.end ?? 0) - 30) < 0.001)
    }

    @Test func aSingleWordLongerThanACueIsCappedAtTheMaximumDuration() {
        let transcript = FileTranscript(
            sourceFileName: "pause.wav",
            duration: 20,
            modelName: "Model",
            languageCode: "en",
            speakerStatus: .notRequested,
            segments: [TranscriptSegment(start: 0, end: 20, text: "Hmm")]
        )

        let cues = FileTranscriptExporter.cues(for: transcript)

        #expect(cues == [.init(start: 0, end: 7, lines: ["Hmm"])])
    }

    @Test func vttEscapesMarkup() {
        let transcript = FileTranscript(
            sourceFileName: "code.wav",
            duration: 2,
            modelName: "Model",
            languageCode: "en",
            speakerStatus: .notRequested,
            segments: [TranscriptSegment(start: 0, end: 2, text: "a <b> & c")]
        )

        #expect(FileTranscriptExporter.export(transcript, as: .vtt).contains("a &lt;b&gt; &amp; c"))
    }

    // MARK: - Fixture

    /// English then Hebrew, with an English sentence from the Hebrew-named speaker.
    private static let interview: FileTranscript = {
        var transcript = FileTranscript(
            transcriptionID: UUID(uuidString: "6F1A6D2C-3B1E-4C8B-9A77-2D5E0F4B8C11")!,
            sourceFileName: "interview.m4a",
            duration: 12,
            modelName: "Whisper Large v3 Turbo",
            languageCode: "he",
            speakerStatus: .identified,
            segments: [
                TranscriptSegment(start: 0, end: 4, text: "Hello and welcome to the show.", speakerIndex: 0),
                TranscriptSegment(start: 4, end: 9.5, text: "שלום, תודה שהזמנת אותי.", speakerIndex: 1),
                TranscriptSegment(start: 9.5, end: 12, text: "It is great to be here.", speakerIndex: 1)
            ]
        )
        transcript.rename(speaker: 0, to: "Dana")
        transcript.rename(speaker: 1, to: "דוד")
        return transcript
    }()
}
