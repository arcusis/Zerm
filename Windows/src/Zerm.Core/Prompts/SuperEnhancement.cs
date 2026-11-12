namespace Zerm.Core.Prompts;

/// <summary>
/// Super Enhancement: rewrites spoken thought into what the speaker would have written. It repairs
/// repetitions, restarts, self-corrections, abandoned fragments, topic jumps and late afterthoughts
/// without dropping any point the speaker made. Slower than the Default prompt by design.
/// </summary>
public static class SuperEnhancement
{
    public static readonly Guid Id = Guid.Parse("00000000-0000-0000-0000-000000000005");

    public const string Title = "Super Enhancement";

    public const string Text = """
        - The <TRANSCRIPT> was SPOKEN, not written. People think while they talk: they repeat words while searching for the next one ("and it was, and it was"), restart sentences, abandon a thought halfway and jump to another, correct themselves, and add points they forgot later on. Rewrite it into what the speaker would have written if they had typed it carefully.
        - First work out what the speaker meant, then write it:
          1. Repeated words and phrases: keep one copy. "I want the the report and it was and it was late" → "I wanted the report, and it was late."
          2. Restarts and false starts: when a sentence is cut off and started again, keep only the completed version.
          3. Self-corrections in any language — English "actually", "I mean", "no wait", "sorry, not that"; Hebrew "לא רגע", "רגע", "בעצם", "כלומר", "סליחה", "לא, " — keep only the final intent.
          4. Abandoned fragments: drop a fragment that goes nowhere; if it carries information, merge that information into the sentence it belongs to.
          5. Topic jumps: when the speaker switches subject, finish the previous sentence cleanly and start a new sentence or paragraph. Never fuse two unrelated thoughts into one sentence.
          6. Afterthoughts ("oh and also", "I forgot to say", "going back to"): attach them to the part they belong to.
          7. Verbal filler that adds nothing ("like", "you know", "kind of", "basically", "so yeah", "I guess" used as filler).
          8. Talk about talking ("I was going to say that", "what I mean is", "let me think", "how do I put it"): drop it and keep what was said.
        - Then write complete, natural sentences with correct grammar and punctuation. Keep the speaker's own words, voice and level of formality wherever possible; only restructure what is broken. Use paragraphs or a list when the content clearly has that shape.
        - Keep EVERY fact, name, number, request, example and nuance. This is a cleanup, not a summary: remove only the noise of speaking, never content. Do not add information, opinions or conclusions the speaker did not express.
        - If something is genuinely ambiguous, keep the speaker's wording instead of guessing.
        - Examples (input → output). Notice that every repeat, correction and meta phrase disappears, and every fact stays. "[new paragraph]" stands for a blank line — write a real blank line, never those words:
          - "so the the report is is ready I mean almost ready we just need the the numbers from dana oh and also the meeting tomorrow is moved to three" → "The report is almost ready; we just need the numbers from Dana. [new paragraph] Also, tomorrow's meeting has moved to 3."
          - "I was going to say that the new design looks great but the login page it's it's broken on mobile the button doesn't show up" → "The new design looks great, but the login page is broken on mobile: the button doesn't show up."
          - "please call the client on monday no wait tuesday morning and tell them the price is two hundred I mean two fifty" → "Please call the client on Tuesday morning and tell them the price is 250."
          - "the app crashed when I when I opened the um the camera and it was and it was really slow before that anyway the bigger problem is the login" → "The app crashed when I opened the camera, and it was really slow before that. [new paragraph] The bigger problem, though, is the login."
          - "can you can you send me the the file when you when you get a chance" → "Can you send me the file when you get a chance?"
          - "תתקשר ל ל לקוח ביום שני לא רגע ביום שלישי ו ו תגיד לו שהמחיר הוא מאתיים כלומר מאתיים וחמישים" → "תתקשר ללקוח ביום שלישי ותגיד לו שהמחיר הוא 250."
        - Output only the rewritten text.
        """;

    /// <summary>Second pass: removes speech leftovers the rewrite missed, and nothing else.</summary>
    public const string ReviewText = """
        - The <TRANSCRIPT> is a dictation that was already cleaned up but may still contain leftovers of speaking. Fix ONLY these leftovers and keep everything else exactly as it is, word for word:
          1. A correction left in place — keep only the corrected part: "on Monday, no wait, Tuesday" → "on Tuesday"; "because yesterday, no wait, the day before yesterday, the server crashed" → "because the server crashed the day before yesterday"; "two hundred, I mean two fifty" → "250"; "שיהיה מוכן מחר, לא רגע ביום רביעי" → "שיהיה מוכן ביום רביעי".
          2. A word or phrase said twice in a row: keep one.
          3. Talk about talking ("I was going to say that", "what I mean is", "let me think"): remove it.
        - Do not rephrase, shorten, summarize or add anything else. If there are no leftovers, return the text exactly unchanged.
        - Output only the text.
        """;

    /// <summary>
    /// Runs the rewrite, then the review pass on its output. The review is kept only if it is a valid
    /// enhancement of the first pass; otherwise the first pass stands.
    /// </summary>
    public static async Task<Enhancement.EnhancementOutcome> RunAsync(Enhancement.EnhancementExecutor executor, Enhancement.EnhancementRequest request, CancellationToken ct)
    {
        var first = await executor.RunAsync(request, ct);
        if (first.Kind != Enhancement.EnhancementOutcomeKind.Enhanced || first.Text == null) return first;
        // Small local models resolve Hebrew self-corrections unreliably (in testing the review kept the
        // corrected-away word and dropped the correction). Correct beats clean: Hebrew-heavy text keeps pass one.
        if (Enhancement.EnhancementLanguageGuard.Histogram(first.Text).Ratio(Enhancement.EnhancementLanguageGuard.Script.Hebrew) >= 0.3)
            return first;
        var review = request with
        {
            InputText = first.Text,
            SystemMessage = PromptTexts.CustomPromptTemplate.Replace("%@", ReviewText),
            UserMessage = $"\n<TRANSCRIPT>\n{first.Text}\n</TRANSCRIPT>",
            RetriesOnTimeout = false,
        };
        var second = await executor.RunAsync(review, ct);
        if (second.Kind == Enhancement.EnhancementOutcomeKind.Cancelled) return second;
        var duration = first.Duration + second.Duration;
        return second.Kind == Enhancement.EnhancementOutcomeKind.Enhanced && second.Text != null
            ? second with { Duration = duration }
            : first with { Duration = duration };
    }

    public static CustomPrompt Prompt => new()
    {
        Id = Id,
        Title = Title,
        PromptText = Text,
        Icon = "brain.head.profile",
        Description = "Understands spoken thought: removes repeats, restarts and self-corrections and rebuilds clean sentences. Slower.",
        IsPredefined = true,
        UseSystemInstructions = true,
    };
}
