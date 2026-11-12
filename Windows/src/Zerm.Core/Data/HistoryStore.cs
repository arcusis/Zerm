using Microsoft.Data.Sqlite;

namespace Zerm.Core.Data;

public enum TranscriptionStatus { Pending, Completed, Failed }

/// <summary>Port of the SwiftData Transcription model.</summary>
public sealed class TranscriptionRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Text { get; set; } = "";
    public string? EnhancedText { get; set; }
    public DateTime Timestamp { get; set; } = DateTime.Now;
    public double Duration { get; set; }
    public string? AudioFilePath { get; set; }
    public string? TranscriptionModelName { get; set; }
    public string? AiEnhancementModelName { get; set; }
    public string? PromptName { get; set; }
    public double? TranscriptionDuration { get; set; }
    public double? EnhancementDuration { get; set; }
    public string? AiRequestSystemMessage { get; set; }
    public string? AiRequestUserMessage { get; set; }
    public string? PowerModeName { get; set; }
    public string? PowerModeEmoji { get; set; }
    public TranscriptionStatus Status { get; set; } = TranscriptionStatus.Pending;
    public string? EnhancementOutcome { get; set; }
    public string? EnhancementOutcomeReason { get; set; }
    public string? SegmentsJson { get; set; }

    public bool HasEnhancement => !string.IsNullOrWhiteSpace(EnhancedText);
    public string DisplayText => HasEnhancement ? EnhancedText! : Text;
    public bool HasAudio => AudioFilePath != null && File.Exists(AudioFilePath);
}

public sealed class UsageDay
{
    public DateTime Day { get; set; }
    public int Sessions { get; set; }
    public int Words { get; set; }
    public int EnhancedSessions { get; set; }
    public double RecordedSeconds { get; set; }
    public double TranscribeSeconds { get; set; }
    public double EnhanceSeconds { get; set; }
    public int ReadAloudWords { get; set; }
    public int ReadAloudSessions { get; set; }
}

public sealed class ReadAloudEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime Timestamp { get; set; } = DateTime.Now;
    public string Mode { get; set; } = "Exact";
    public string SourceText { get; set; } = "";
    public string SpokenText { get; set; } = "";
    public string Provider { get; set; } = "";
    public string Voice { get; set; } = "";
    public string? Model { get; set; }
}

/// <summary>SQLite store for dictation history, usage statistics and Read Aloud history.</summary>
public sealed class HistoryStore : IDisposable
{
    private readonly SqliteConnection _db;
    private readonly object _gate = new();

    public event Action? Changed;

    public HistoryStore(string? path = null)
    {
        _db = new SqliteConnection($"Data Source={path ?? AppPaths.Database}");
        _db.Open();
        Exec("PRAGMA journal_mode=WAL;");
        Exec("""
            CREATE TABLE IF NOT EXISTS transcriptions (
                id TEXT PRIMARY KEY, text TEXT NOT NULL, enhanced_text TEXT, timestamp TEXT NOT NULL,
                duration REAL NOT NULL, audio_path TEXT, model TEXT, ai_model TEXT, prompt TEXT,
                transcription_duration REAL, enhancement_duration REAL, ai_system TEXT, ai_user TEXT,
                power_mode_name TEXT, power_mode_emoji TEXT, status TEXT NOT NULL,
                enhancement_outcome TEXT, enhancement_reason TEXT, segments TEXT);
            CREATE INDEX IF NOT EXISTS ix_transcriptions_ts ON transcriptions(timestamp);
            CREATE TABLE IF NOT EXISTS usage_days (
                day TEXT PRIMARY KEY, sessions INTEGER NOT NULL DEFAULT 0, words INTEGER NOT NULL DEFAULT 0,
                enhanced_sessions INTEGER NOT NULL DEFAULT 0, recorded_seconds REAL NOT NULL DEFAULT 0,
                transcribe_seconds REAL NOT NULL DEFAULT 0, enhance_seconds REAL NOT NULL DEFAULT 0,
                read_aloud_words INTEGER NOT NULL DEFAULT 0, read_aloud_sessions INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS read_aloud (
                id TEXT PRIMARY KEY, timestamp TEXT NOT NULL, mode TEXT NOT NULL, source TEXT NOT NULL,
                spoken TEXT NOT NULL, provider TEXT NOT NULL, voice TEXT NOT NULL, model TEXT);
            """);
    }

    private void Exec(string sql)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static string Iso(DateTime d) => d.ToString("o");
    private static object Db(object? v) => v ?? DBNull.Value;

    // MARK: - Transcriptions

    public void Upsert(TranscriptionRecord r)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = """
                INSERT INTO transcriptions VALUES ($id,$text,$enh,$ts,$dur,$audio,$model,$ai,$prompt,$tdur,$edur,$sys,$user,$pmn,$pme,$status,$outcome,$reason,$segs)
                ON CONFLICT(id) DO UPDATE SET text=$text, enhanced_text=$enh, timestamp=$ts, duration=$dur, audio_path=$audio, model=$model,
                ai_model=$ai, prompt=$prompt, transcription_duration=$tdur, enhancement_duration=$edur, ai_system=$sys, ai_user=$user,
                power_mode_name=$pmn, power_mode_emoji=$pme, status=$status, enhancement_outcome=$outcome, enhancement_reason=$reason, segments=$segs;
                """;
            cmd.Parameters.AddWithValue("$id", r.Id.ToString());
            cmd.Parameters.AddWithValue("$text", r.Text);
            cmd.Parameters.AddWithValue("$enh", Db(r.EnhancedText));
            cmd.Parameters.AddWithValue("$ts", Iso(r.Timestamp));
            cmd.Parameters.AddWithValue("$dur", r.Duration);
            cmd.Parameters.AddWithValue("$audio", Db(r.AudioFilePath));
            cmd.Parameters.AddWithValue("$model", Db(r.TranscriptionModelName));
            cmd.Parameters.AddWithValue("$ai", Db(r.AiEnhancementModelName));
            cmd.Parameters.AddWithValue("$prompt", Db(r.PromptName));
            cmd.Parameters.AddWithValue("$tdur", Db(r.TranscriptionDuration));
            cmd.Parameters.AddWithValue("$edur", Db(r.EnhancementDuration));
            cmd.Parameters.AddWithValue("$sys", Db(r.AiRequestSystemMessage));
            cmd.Parameters.AddWithValue("$user", Db(r.AiRequestUserMessage));
            cmd.Parameters.AddWithValue("$pmn", Db(r.PowerModeName));
            cmd.Parameters.AddWithValue("$pme", Db(r.PowerModeEmoji));
            cmd.Parameters.AddWithValue("$status", r.Status.ToString());
            cmd.Parameters.AddWithValue("$outcome", Db(r.EnhancementOutcome));
            cmd.Parameters.AddWithValue("$reason", Db(r.EnhancementOutcomeReason));
            cmd.Parameters.AddWithValue("$segs", Db(r.SegmentsJson));
            cmd.ExecuteNonQuery();
        }
        Changed?.Invoke();
    }

    private static TranscriptionRecord Read(SqliteDataReader r) => new()
    {
        Id = Guid.Parse(r.GetString(0)),
        Text = r.GetString(1),
        EnhancedText = r.IsDBNull(2) ? null : r.GetString(2),
        Timestamp = DateTime.Parse(r.GetString(3), null, System.Globalization.DateTimeStyles.RoundtripKind),
        Duration = r.GetDouble(4),
        AudioFilePath = r.IsDBNull(5) ? null : r.GetString(5),
        TranscriptionModelName = r.IsDBNull(6) ? null : r.GetString(6),
        AiEnhancementModelName = r.IsDBNull(7) ? null : r.GetString(7),
        PromptName = r.IsDBNull(8) ? null : r.GetString(8),
        TranscriptionDuration = r.IsDBNull(9) ? null : r.GetDouble(9),
        EnhancementDuration = r.IsDBNull(10) ? null : r.GetDouble(10),
        AiRequestSystemMessage = r.IsDBNull(11) ? null : r.GetString(11),
        AiRequestUserMessage = r.IsDBNull(12) ? null : r.GetString(12),
        PowerModeName = r.IsDBNull(13) ? null : r.GetString(13),
        PowerModeEmoji = r.IsDBNull(14) ? null : r.GetString(14),
        Status = Enum.TryParse<TranscriptionStatus>(r.GetString(15), out var s) ? s : TranscriptionStatus.Completed,
        EnhancementOutcome = r.IsDBNull(16) ? null : r.GetString(16),
        EnhancementOutcomeReason = r.IsDBNull(17) ? null : r.GetString(17),
        SegmentsJson = r.IsDBNull(18) ? null : r.GetString(18),
    };

    /// <summary>Paged, searchable query (InlineHistoryView: 20 per page, search text or enhanced text).</summary>
    public List<TranscriptionRecord> Query(string? search = null, bool newestFirst = true, bool withAudioOnly = false, int limit = 20, int offset = 0)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            var where = new List<string>();
            if (!string.IsNullOrWhiteSpace(search))
            {
                where.Add("(text LIKE $q ESCAPE '\\' OR enhanced_text LIKE $q ESCAPE '\\')");
                var escaped = search.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");
                cmd.Parameters.AddWithValue("$q", $"%{escaped}%");
            }
            if (withAudioOnly) where.Add("audio_path IS NOT NULL");
            cmd.CommandText = "SELECT * FROM transcriptions" +
                              (where.Count > 0 ? " WHERE " + string.Join(" AND ", where) : "") +
                              $" ORDER BY timestamp {(newestFirst ? "DESC" : "ASC")} LIMIT $limit OFFSET $offset";
            cmd.Parameters.AddWithValue("$limit", limit);
            cmd.Parameters.AddWithValue("$offset", offset);
            using var reader = cmd.ExecuteReader();
            var list = new List<TranscriptionRecord>();
            while (reader.Read()) list.Add(Read(reader));
            return list;
        }
    }

    public int Count(string? search = null, bool withAudioOnly = false)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            var where = new List<string>();
            if (!string.IsNullOrWhiteSpace(search))
            {
                where.Add("(text LIKE $q ESCAPE '\\' OR enhanced_text LIKE $q ESCAPE '\\')");
                cmd.Parameters.AddWithValue("$q", $"%{search.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_")}%");
            }
            if (withAudioOnly) where.Add("audio_path IS NOT NULL");
            cmd.CommandText = "SELECT COUNT(*) FROM transcriptions" + (where.Count > 0 ? " WHERE " + string.Join(" AND ", where) : "");
            return Convert.ToInt32(cmd.ExecuteScalar());
        }
    }

    public TranscriptionRecord? Get(Guid id) => QueryWhere("id = $v", id.ToString()).FirstOrDefault();

    public TranscriptionRecord? Latest() =>
        QueryWhere("status = $v", TranscriptionStatus.Completed.ToString(), "ORDER BY timestamp DESC LIMIT 1").FirstOrDefault();

    /// <summary>All records since a moment, newest first (Enhancement Insights).</summary>
    public List<TranscriptionRecord> Since(DateTime since, int limit = 5000) =>
        QueryWhere("timestamp >= $v", Iso(since), $"ORDER BY timestamp DESC LIMIT {limit}");

    public TranscriptionRecord? LatestWithAudio() =>
        QueryWhere("audio_path IS NOT NULL", null, "ORDER BY timestamp DESC LIMIT 1").FirstOrDefault();

    private List<TranscriptionRecord> QueryWhere(string where, string? value, string suffix = "")
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = $"SELECT * FROM transcriptions WHERE {where} {suffix}";
            if (value != null) cmd.Parameters.AddWithValue("$v", value);
            using var reader = cmd.ExecuteReader();
            var list = new List<TranscriptionRecord>();
            while (reader.Read()) list.Add(Read(reader));
            return list;
        }
    }

    public void Delete(IEnumerable<Guid> ids, bool deleteAudio = true)
    {
        lock (_gate)
        {
            foreach (var id in ids)
            {
                var rec = QueryWhere("id = $v", id.ToString()).FirstOrDefault();
                if (rec?.AudioFilePath != null && deleteAudio)
                {
                    try { File.Delete(rec.AudioFilePath); } catch { }
                }
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "DELETE FROM transcriptions WHERE id = $id";
                cmd.Parameters.AddWithValue("$id", id.ToString());
                cmd.ExecuteNonQuery();
            }
        }
        Changed?.Invoke();
    }

    /// <summary>Retention (AudioCleanupManager): deletes old transcripts and/or old audio files.</summary>
    public (int Transcripts, int AudioFiles) Cleanup(int? transcriptRetentionMinutes, int? audioRetentionDays)
    {
        int transcripts = 0, audio = 0;
        lock (_gate)
        {
            if (audioRetentionDays is { } days)
            {
                var cutoff = DateTime.Now.AddDays(-days);
                foreach (var r in QueryWhere("audio_path IS NOT NULL AND timestamp < $v", Iso(cutoff)))
                {
                    try { if (File.Exists(r.AudioFilePath)) { File.Delete(r.AudioFilePath!); audio++; } } catch { }
                    r.AudioFilePath = null;
                    UpsertNoEvent(r);
                }
            }
            if (transcriptRetentionMinutes is { } minutes)
            {
                var cutoff = DateTime.Now.AddMinutes(-minutes);
                var old = QueryWhere("timestamp < $v", Iso(cutoff));
                foreach (var r in old)
                    if (r.AudioFilePath != null) try { File.Delete(r.AudioFilePath); audio++; } catch { }
                using var cmd = _db.CreateCommand();
                cmd.CommandText = "DELETE FROM transcriptions WHERE timestamp < $v";
                cmd.Parameters.AddWithValue("$v", Iso(cutoff));
                transcripts = cmd.ExecuteNonQuery();
            }
        }
        Changed?.Invoke();
        return (transcripts, audio);
    }

    private void UpsertNoEvent(TranscriptionRecord r)
    {
        using var cmd = _db.CreateCommand();
        cmd.CommandText = "UPDATE transcriptions SET audio_path = $a WHERE id = $id";
        cmd.Parameters.AddWithValue("$a", Db(r.AudioFilePath));
        cmd.Parameters.AddWithValue("$id", r.Id.ToString());
        cmd.ExecuteNonQuery();
    }

    // MARK: - Usage

    public void RecordUsage(DateTime when, int sessions = 0, int words = 0, int enhancedSessions = 0, double recordedSeconds = 0,
        double transcribeSeconds = 0, double enhanceSeconds = 0, int readAloudWords = 0, int readAloudSessions = 0)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = """
                INSERT INTO usage_days VALUES ($d,$s,$w,$e,$r,$t,$h,$raw,$ras)
                ON CONFLICT(day) DO UPDATE SET sessions=sessions+$s, words=words+$w, enhanced_sessions=enhanced_sessions+$e,
                recorded_seconds=recorded_seconds+$r, transcribe_seconds=transcribe_seconds+$t, enhance_seconds=enhance_seconds+$h,
                read_aloud_words=read_aloud_words+$raw, read_aloud_sessions=read_aloud_sessions+$ras;
                """;
            cmd.Parameters.AddWithValue("$d", when.Date.ToString("yyyy-MM-dd"));
            cmd.Parameters.AddWithValue("$s", sessions);
            cmd.Parameters.AddWithValue("$w", words);
            cmd.Parameters.AddWithValue("$e", enhancedSessions);
            cmd.Parameters.AddWithValue("$r", recordedSeconds);
            cmd.Parameters.AddWithValue("$t", transcribeSeconds);
            cmd.Parameters.AddWithValue("$h", enhanceSeconds);
            cmd.Parameters.AddWithValue("$raw", readAloudWords);
            cmd.Parameters.AddWithValue("$ras", readAloudSessions);
            cmd.ExecuteNonQuery();
        }
        Changed?.Invoke();
    }

    public List<UsageDay> UsageDays()
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT * FROM usage_days ORDER BY day";
            using var r = cmd.ExecuteReader();
            var list = new List<UsageDay>();
            while (r.Read())
                list.Add(new UsageDay
                {
                    Day = DateTime.ParseExact(r.GetString(0), "yyyy-MM-dd", null),
                    Sessions = r.GetInt32(1), Words = r.GetInt32(2), EnhancedSessions = r.GetInt32(3),
                    RecordedSeconds = r.GetDouble(4), TranscribeSeconds = r.GetDouble(5), EnhanceSeconds = r.GetDouble(6),
                    ReadAloudWords = r.GetInt32(7), ReadAloudSessions = r.GetInt32(8),
                });
            return list;
        }
    }

    public void ResetUsage()
    {
        lock (_gate) Exec("DELETE FROM usage_days;");
        Changed?.Invoke();
    }

    // MARK: - Read Aloud history (capped at 500, newest first)

    public void AddReadAloud(ReadAloudEntry e)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "INSERT INTO read_aloud VALUES ($id,$ts,$mode,$src,$spoken,$prov,$voice,$model);" +
                              "DELETE FROM read_aloud WHERE id NOT IN (SELECT id FROM read_aloud ORDER BY timestamp DESC LIMIT 500);";
            cmd.Parameters.AddWithValue("$id", e.Id.ToString());
            cmd.Parameters.AddWithValue("$ts", Iso(e.Timestamp));
            cmd.Parameters.AddWithValue("$mode", e.Mode);
            cmd.Parameters.AddWithValue("$src", e.SourceText);
            cmd.Parameters.AddWithValue("$spoken", e.SpokenText);
            cmd.Parameters.AddWithValue("$prov", e.Provider);
            cmd.Parameters.AddWithValue("$voice", e.Voice);
            cmd.Parameters.AddWithValue("$model", Db(e.Model));
            cmd.ExecuteNonQuery();
        }
        Changed?.Invoke();
    }

    public List<ReadAloudEntry> ReadAloudHistory()
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT * FROM read_aloud ORDER BY timestamp DESC";
            using var r = cmd.ExecuteReader();
            var list = new List<ReadAloudEntry>();
            while (r.Read())
                list.Add(new ReadAloudEntry
                {
                    Id = Guid.Parse(r.GetString(0)),
                    Timestamp = DateTime.Parse(r.GetString(1), null, System.Globalization.DateTimeStyles.RoundtripKind),
                    Mode = r.GetString(2), SourceText = r.GetString(3), SpokenText = r.GetString(4),
                    Provider = r.GetString(5), Voice = r.GetString(6), Model = r.IsDBNull(7) ? null : r.GetString(7),
                });
            return list;
        }
    }

    public void DeleteReadAloud(Guid? id = null)
    {
        lock (_gate)
        {
            using var cmd = _db.CreateCommand();
            cmd.CommandText = id == null ? "DELETE FROM read_aloud" : "DELETE FROM read_aloud WHERE id = $id";
            if (id != null) cmd.Parameters.AddWithValue("$id", id.ToString());
            cmd.ExecuteNonQuery();
        }
        Changed?.Invoke();
    }

    public void Dispose() => _db.Dispose();
}
