using System.Text.RegularExpressions;

namespace Zerm.Core.Text;

/// <summary>
/// Port of WhisperTextFormatter.swift: groups sentences into readable paragraphs of
/// roughly 50 words with at most 4 significant (4+ word) sentences each.
/// </summary>
public static class TextFormatter
{
    private const int TargetWordCount = 50;
    private const int MaxSentencesPerChunk = 4;
    private const int MinWordsForSignificantSentence = 4;

    // A sentence ends at . ! ? … (optionally followed by closing quotes/brackets) then whitespace.
    private static readonly Regex SentenceBoundary =
        new(@"(?<=[.!?…。！？][""'”’)\]]*)\s+", RegexOptions.Compiled);
    private static readonly Regex WordToken = new(@"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*", RegexOptions.Compiled);

    public static List<string> SplitSentences(string text) =>
        SentenceBoundary.Split(text)
            .Select(s => s.Trim())
            .Where(s => s.Length > 0)
            .ToList();

    public static int CountWords(string sentence) => WordToken.Matches(sentence).Count;

    public static string Format(string text)
    {
        var sentences = SplitSentences(text);
        if (sentences.Count == 0) return "";

        var paragraphs = new List<string>();
        var index = 0;
        while (index < sentences.Count)
        {
            var tentative = new List<string>();
            var words = 0;
            var significant = 0;
            for (var i = index; i < sentences.Count; i++)
            {
                var count = CountWords(sentences[i]);
                tentative.Add(sentences[i]);
                words += count;
                if (count >= MinWordsForSignificantSentence) significant++;
                if (words >= TargetWordCount) break;
            }

            List<string> chunk;
            if (significant > MaxSentencesPerChunk)
            {
                chunk = [];
                var counted = 0;
                foreach (var s in tentative)
                {
                    chunk.Add(s);
                    if (CountWords(s) >= MinWordsForSignificantSentence && ++counted >= MaxSentencesPerChunk)
                        break;
                }
            }
            else
            {
                chunk = tentative;
            }

            if (chunk.Count == 0) break;
            paragraphs.Add(string.Join(" ", chunk));
            index += chunk.Count;
        }

        return string.Join("\n\n", paragraphs).Trim();
    }
}
