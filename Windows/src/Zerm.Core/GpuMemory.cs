using System.Runtime.InteropServices;

namespace Zerm.Core;

/// <summary>
/// Free video memory from DXGI (IDXGIAdapter3::QueryVideoMemoryInfo): the OS budget for this process
/// minus what it already uses, on the adapter with the most room. Used to avoid overcommitting the GPU,
/// which spills into shared memory and makes inference many times slower.
/// </summary>
public static class GpuMemory
{
    [DllImport("dxgi.dll")]
    private static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);

    [StructLayout(LayoutKind.Sequential)]
    private struct VideoMemoryInfo
    {
        public ulong Budget, CurrentUsage, AvailableForReservation, CurrentReservation;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct AdapterDesc1
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubSysId, Revision;
        public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public long AdapterLuid;
        public uint Flags;
    }

    private delegate int EnumAdapters1(IntPtr self, uint index, out IntPtr adapter);
    private delegate int GetDesc1(IntPtr self, out AdapterDesc1 desc);
    private delegate int QueryInterface(IntPtr self, ref Guid riid, out IntPtr obj);
    private delegate int QueryVideoMemoryInfo(IntPtr self, uint node, int group, out VideoMemoryInfo info);

    private static T Slot<T>(IntPtr com, int index) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(com), index * IntPtr.Size));

    private static long? UsedByAllProcesses(long luid)
    {
        try
        {
            var key = $"luid_0x{(uint)(luid >> 32):X8}_0x{(uint)(luid & 0xFFFFFFFF):X8}";
            var category = new System.Diagnostics.PerformanceCounterCategory("GPU Adapter Memory");
            long total = 0;
            var found = false;
            foreach (var instance in category.GetInstanceNames().Where(n => n.StartsWith(key, StringComparison.OrdinalIgnoreCase)))
            {
                using var counter = new System.Diagnostics.PerformanceCounter("GPU Adapter Memory", "Dedicated Usage", instance, true);
                total += counter.RawValue;
                found = true;
            }
            return found ? total : null;
        }
        catch
        {
            return null;
        }
    }

    private static (DateTime At, long? Value) _cache;

    /// <returns>Free bytes on the roomiest GPU, or null when it cannot be determined (cached 5 s).</returns>
    public static long? AvailableBytes()
    {
        var cached = _cache;
        if (DateTime.UtcNow - cached.At < TimeSpan.FromSeconds(5)) return cached.Value;
        var value = Query();
        _cache = (DateTime.UtcNow, value);
        return value;
    }

    /// <summary>Forgets the cached value (call after loading or unloading a model).</summary>
    public static void Invalidate() => _cache = default;

    private static long? Query()
    {
        try
        {
            var factoryId = new Guid("770aae78-f26f-4dba-a829-253c83d1b387"); // IDXGIFactory1
            var adapter3Id = new Guid("645967a4-1392-4310-a798-8053ce3e93fd"); // IDXGIAdapter3
            if (CreateDXGIFactory1(ref factoryId, out var factory) < 0) return null;
            long? best = null;
            try
            {
                for (uint i = 0; ; i++)
                {
                    if (Slot<EnumAdapters1>(factory, 12)(factory, i, out var adapter) < 0) break;
                    try
                    {
                        // Only real GPUs with their own memory (skip the software "Basic Render Driver").
                        if (Slot<GetDesc1>(adapter, 10)(adapter, out var desc) < 0 || (desc.Flags & 2) != 0
                            || desc.DedicatedVideoMemory.ToUInt64() < 512UL * 1024 * 1024) continue;
                        if (Slot<QueryInterface>(adapter, 0)(adapter, ref adapter3Id, out var adapter3) < 0) continue;
                        try
                        {
                            if (Slot<QueryVideoMemoryInfo>(adapter3, 14)(adapter3, 0, 0 /* LOCAL */, out var info) >= 0 && info.Budget > 0)
                            {
                                // DXGI's budget ignores memory held by other apps; the GPU performance counters
                                // include every process, so subtract their total from the card's memory.
                                var free = (long)info.Budget - (long)info.CurrentUsage;
                                if (UsedByAllProcesses(desc.AdapterLuid) is { } used)
                                    free = Math.Min(free, (long)desc.DedicatedVideoMemory.ToUInt64() - used);
                                Log.Debug($"GPU {desc.Description}: budget {info.Budget >> 20} MB, used {info.CurrentUsage >> 20} MB");
                                if (best == null || free > best) best = free;
                            }
                        }
                        finally { Marshal.Release(adapter3); }
                    }
                    finally { Marshal.Release(adapter); }
                }
            }
            finally { Marshal.Release(factory); }
            return best;
        }
        catch (Exception ex)
        {
            Log.Debug($"VRAM query failed: {ex.Message}");
            return null;
        }
    }
}
