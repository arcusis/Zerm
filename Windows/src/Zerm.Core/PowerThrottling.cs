using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Zerm.Core;

/// <summary>
/// Zerm works while another app is in the foreground, so Windows treats it as a background process and
/// applies EcoQoS (efficiency cores, low clocks). That made on-device inference 5–10× slower in testing
/// (Kokoro: ~9 s → ~1 s per sentence). Opting out keeps transcription and speech responsive.
/// </summary>
public static class PowerThrottling
{
    private const int ProcessPowerThrottling = 4;
    private const uint ExecutionSpeed = 0x1;
    private const uint IgnoreTimerResolution = 0x4;

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessPowerThrottlingState
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessInformation(IntPtr process, int infoClass, ref ProcessPowerThrottlingState info, int size);

    public static bool OptOut()
    {
        try
        {
            var state = new ProcessPowerThrottlingState { Version = 1, ControlMask = ExecutionSpeed | IgnoreTimerResolution, StateMask = 0 };
            var ok = SetProcessInformation(Process.GetCurrentProcess().Handle, ProcessPowerThrottling, ref state, Marshal.SizeOf<ProcessPowerThrottlingState>());
            Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.AboveNormal;
            return ok;
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not opt out of power throttling: {ex.Message}");
            return false;
        }
    }

    /// <summary>Threads for ONNX/ggml inference: physical-ish cores, leaving headroom for the UI.</summary>
    public static int InferenceThreads => Math.Clamp(Environment.ProcessorCount / 2, 2, 8);
}
