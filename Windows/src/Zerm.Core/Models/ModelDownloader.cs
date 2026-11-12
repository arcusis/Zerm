using System.Net.Http.Headers;
using System.Security.Cryptography;
using SharpCompress.Archives;
using SharpCompress.Common;
using SharpCompress.Readers;
using Zerm.Core.Net;

namespace Zerm.Core.Models;

/// <param name="Sha256">Expected checksum, or null to skip verification.</param>
/// <param name="ExtractTo">When set, the downloaded archive (.tar.bz2) is extracted into this folder and deleted.</param>
public sealed record DownloadSpec(string Url, string Destination, string? Sha256, long ApproximateSize, string? ExtractTo = null);

public sealed record DownloadProgress(long Received, long Total, double BytesPerSecond)
{
    public double Fraction => Total > 0 ? Math.Clamp((double)Received / Total, 0, 1) : 0;
}

public sealed class ChecksumMismatchException(string file) : Exception($"The downloaded file failed its integrity check: {file}");

/// <summary>
/// Resumable downloads (a ".part" file plus an HTTP Range request), SHA-256 verification and archive
/// extraction — the Windows counterpart of the model download managers on macOS.
/// </summary>
public static class ModelDownloader
{
    public static async Task DownloadAsync(DownloadSpec spec, IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(spec.Destination)!);
        var part = spec.Destination + ".part";
        var existing = File.Exists(part) ? new FileInfo(part).Length : 0;

        using var request = new HttpRequestMessage(HttpMethod.Get, spec.Url);
        if (existing > 0) request.Headers.Range = new RangeHeaderValue(existing, null);
        using var response = await Http.Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (response.StatusCode == System.Net.HttpStatusCode.RequestedRangeNotSatisfiable)
        {
            // The part file is already complete (or corrupt) — start over.
            File.Delete(part);
            await DownloadAsync(spec, progress, ct);
            return;
        }
        if (!response.IsSuccessStatusCode)
            throw new ApiException(response.StatusCode, $"Download failed: HTTP {(int)response.StatusCode}");

        var resumed = response.StatusCode == System.Net.HttpStatusCode.PartialContent;
        if (!resumed) existing = 0;
        var total = existing + (response.Content.Headers.ContentLength ?? Math.Max(0, spec.ApproximateSize - existing));

        await using (var input = await response.Content.ReadAsStreamAsync(ct))
        await using (var output = new FileStream(part, resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
        {
            var buffer = new byte[1 << 16];
            var received = existing;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            long lastReport = 0, windowBytes = 0;
            int read;
            while ((read = await input.ReadAsync(buffer, ct)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read), ct);
                received += read;
                windowBytes += read;
                if (sw.ElapsedMilliseconds - lastReport > 200)
                {
                    var seconds = Math.Max(0.001, (sw.ElapsedMilliseconds - lastReport) / 1000.0);
                    progress?.Report(new DownloadProgress(received, total, windowBytes / seconds));
                    lastReport = sw.ElapsedMilliseconds;
                    windowBytes = 0;
                }
            }
            progress?.Report(new DownloadProgress(received, Math.Max(total, received), 0));
        }

        if (spec.Sha256 != null)
        {
            var actual = await Sha256Async(part, ct);
            if (!string.Equals(actual, spec.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(part);
                throw new ChecksumMismatchException(Path.GetFileName(spec.Destination));
            }
        }

        if (spec.ExtractTo != null)
        {
            await Task.Run(() => ExtractArchive(part, spec.ExtractTo, ct), ct);
            File.Delete(part);
        }
        else
        {
            File.Move(part, spec.Destination, overwrite: true);
        }
    }

    public static async Task<string> Sha256Async(string path, CancellationToken ct)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, ct);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    /// <summary>Extracts a .tar.bz2 / .tar.gz / .zip. A single top-level folder in the archive is flattened.</summary>
    public static void ExtractArchive(string archivePath, string destination, CancellationToken ct = default)
    {
        var temp = destination + ".extracting";
        if (Directory.Exists(temp)) Directory.Delete(temp, true);
        Directory.CreateDirectory(temp);
        using (var stream = File.OpenRead(archivePath))
        using (var reader = ReaderFactory.OpenReader(stream))
        {
            while (reader.MoveToNextEntry())
            {
                ct.ThrowIfCancellationRequested();
                if (reader.Entry.IsDirectory) continue;
                reader.WriteEntryToDirectory(temp, new ExtractionOptions { ExtractFullPath = true, Overwrite = true });
            }
        }

        var root = temp;
        var entries = Directory.GetFileSystemEntries(temp);
        if (entries.Length == 1 && Directory.Exists(entries[0])) root = entries[0];

        if (Directory.Exists(destination)) Directory.Delete(destination, true);
        Directory.Move(root, destination);
        if (Directory.Exists(temp)) Directory.Delete(temp, true);
    }

    public static void DeletePartial(DownloadSpec spec)
    {
        try { File.Delete(spec.Destination + ".part"); } catch { }
    }

    public static bool HasPartial(DownloadSpec spec) => File.Exists(spec.Destination + ".part");
}
