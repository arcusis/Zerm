using System.Runtime.CompilerServices;

namespace Zerm.Tests;

internal static class TestSetup
{
    [ModuleInitializer]
    internal static void Init() => Zerm.Core.PowerThrottling.OptOut();
}
