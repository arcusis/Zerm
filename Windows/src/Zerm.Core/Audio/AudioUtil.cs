using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Zerm.Core.Audio;

public static class AudioUtil
{
    public const int SampleRate = 16000;

    /// <summary>Writes 16 kHz mono 16-bit PCM.</summary>
    public static void WriteWav16k(string path, ReadOnlySpan<float> samples)
    {
        using var writer = new WaveFileWriter(path, new WaveFormat(SampleRate, 16, 1));
        var buffer = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var s = (short)Math.Clamp(samples[i] * 32767f, short.MinValue, short.MaxValue);
            buffer[i * 2] = (byte)s;
            buffer[i * 2 + 1] = (byte)(s >> 8);
        }
        writer.Write(buffer, 0, buffer.Length);
    }

    /// <summary>
    /// Decodes any file Windows can read (WAV, MP3, M4A/AAC, MP4/MOV audio, WMA, FLAC…) to 16 kHz mono floats.
    /// </summary>
    public static float[] LoadAs16kMono(string path)
    {
        using WaveStream reader = Path.GetExtension(path).Equals(".wav", StringComparison.OrdinalIgnoreCase)
            ? new WaveFileReader(path)
            : new MediaFoundationReader(path);
        return ToMono16k(reader.ToSampleProvider(), reader.TotalTime);
    }

    public static float[] ToMono16k(ISampleProvider source, TimeSpan? approxDuration = null)
    {
        ISampleProvider p = source;
        if (p.WaveFormat.Channels == 2) p = new StereoToMonoSampleProvider(p) { LeftVolume = 0.5f, RightVolume = 0.5f };
        else if (p.WaveFormat.Channels > 2) p = new DownmixSampleProvider(p);
        if (p.WaveFormat.SampleRate != SampleRate) p = new WdlResamplingSampleProvider(p, SampleRate);

        var capacity = approxDuration.HasValue ? (int)Math.Min(int.MaxValue / 2, approxDuration.Value.TotalSeconds * SampleRate + SampleRate) : SampleRate * 10;
        var list = new List<float>(Math.Max(capacity, 1024));
        var buf = new float[SampleRate];
        int read;
        while ((read = p.Read(buf.AsSpan())) > 0)
            list.AddRange(buf.AsSpan(0, read));
        return [.. list];
    }

    public static double DurationSeconds(int sampleCount) => sampleCount / (double)SampleRate;

    public static float Peak(ReadOnlySpan<float> samples)
    {
        var peak = 0f;
        foreach (var s in samples) peak = Math.Max(peak, Math.Abs(s));
        return peak;
    }

    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return 0;
        double sum = 0;
        foreach (var s in samples) sum += s * s;
        return (float)Math.Sqrt(sum / samples.Length);
    }

    /// <summary>Normalized 0–1 meter value from a dB scale of −60…0 (Recorder level meter).</summary>
    public static float MeterLevel(float rms)
    {
        if (rms <= 0) return 0;
        var db = 20 * Math.Log10(rms);
        return (float)Math.Clamp((db + 60) / 60, 0, 1);
    }

    private sealed class DownmixSampleProvider(ISampleProvider source) : ISampleProvider
    {
        private float[] _buffer = [];
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);

        public int Read(Span<float> buffer)
        {
            var channels = source.WaveFormat.Channels;
            var needed = buffer.Length * channels;
            if (_buffer.Length < needed) _buffer = new float[needed];
            var read = source.Read(_buffer.AsSpan(0, needed));
            var frames = read / channels;
            for (var f = 0; f < frames; f++)
            {
                float sum = 0;
                for (var c = 0; c < channels; c++) sum += _buffer[f * channels + c];
                buffer[f] = sum / channels;
            }
            return frames;
        }
    }
}
