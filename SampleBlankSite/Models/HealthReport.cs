using System.Text.Json.Serialization;

namespace SampleBlankSite.Models;

[JsonConverter(typeof(JsonStringEnumConverter<HealthLevel>))]
public enum HealthLevel
{
    Ok = 0,
    Info = 1,
    Warn = 2,
    Critical = 3,
}

public record HealthIssue(HealthLevel Level, string Area, string Message);

public class HealthReport
{
    public DateTimeOffset GeneratedAt { get; set; }
    public double CollectMs { get; set; }

    public HealthLevel Overall { get; set; }

    /// <summary>0-100, derived from the number and severity of issues.</summary>
    public int Score { get; set; }

    public List<HealthIssue> Issues { get; set; } = [];

    public HostInfo Host { get; set; } = new();
    public CpuInfo Cpu { get; set; } = new();
    public MemoryInfo Memory { get; set; } = new();
    public List<DiskInfo> Disks { get; set; } = [];
    public NetworkInfo Network { get; set; } = new();
    public List<ServiceStatus> Services { get; set; } = [];
    public List<string> FailedUnits { get; set; } = [];
    public DotNetInfo DotNet { get; set; } = new();
    public List<ProcessEntry> TopProcesses { get; set; } = [];
    public List<ListeningPort> ListeningPorts { get; set; } = [];
    public MaintenanceInfo Maintenance { get; set; } = new();
}

public class HostInfo
{
    public string Hostname { get; set; }
    public string Os { get; set; }
    public string Kernel { get; set; }
    public string Architecture { get; set; }
    public string Virtualization { get; set; }
    public TimeSpan? Uptime { get; set; }
    public DateTimeOffset ServerTime { get; set; }
    public string TimeZone { get; set; }
    public bool? NtpSynced { get; set; }
}

public class CpuInfo
{
    public string Model { get; set; }
    public int Cores { get; set; }
    public double? UsagePercent { get; set; }
    public double? Load1 { get; set; }
    public double? Load5 { get; set; }
    public double? Load15 { get; set; }
}

public class MemoryInfo
{
    public long? TotalBytes { get; set; }
    public long? AvailableBytes { get; set; }
    public long? SwapTotalBytes { get; set; }
    public long? SwapFreeBytes { get; set; }

    public double? UsedPercent =>
        TotalBytes > 0 && AvailableBytes != null ? 100.0 * (TotalBytes.Value - AvailableBytes.Value) / TotalBytes.Value : null;

    public double? SwapUsedPercent =>
        SwapTotalBytes > 0 && SwapFreeBytes != null ? 100.0 * (SwapTotalBytes.Value - SwapFreeBytes.Value) / SwapTotalBytes.Value : null;
}

public class DiskInfo
{
    public string Mount { get; set; }
    public string FileSystem { get; set; }
    public long TotalBytes { get; set; }
    public long FreeBytes { get; set; }
    public double UsedPercent => TotalBytes > 0 ? 100.0 * (TotalBytes - FreeBytes) / TotalBytes : 0;
}

public class NetworkInfo
{
    public List<InterfaceEntry> Interfaces { get; set; } = [];
    public bool? InternetReachable { get; set; }
    public double? InternetLatencyMs { get; set; }
    public bool? DnsWorks { get; set; }
    public string DnsDetail { get; set; }
}

public class InterfaceEntry
{
    public string Name { get; set; }
    public string Status { get; set; }
    public string Mac { get; set; }
    public List<string> Addresses { get; set; } = [];
}

public class DotNetInfo
{
    public string AppRuntime { get; set; }
    public List<string> Sdks { get; set; } = [];
    public List<string> Runtimes { get; set; } = [];
    public int ProcessId { get; set; }
    public string ProcessUser { get; set; }
    public long WorkingSetBytes { get; set; }
    public long ManagedHeapBytes { get; set; }
    public int ThreadCount { get; set; }
    public TimeSpan ProcessUptime { get; set; }
}

/// <summary>Processes grouped by name; Count is the number of instances.</summary>
public record ProcessEntry(string Name, int Count, long MemoryBytes);

public record ListeningPort(int Port, bool LocalOnly, string Addresses);

public class MaintenanceInfo
{
    public bool? RebootRequired { get; set; }
    public List<string> RebootPackages { get; set; } = [];
    public int? PendingUpdates { get; set; }
    public int? SecurityUpdates { get; set; }
    public List<string> UpdateNotes { get; set; } = [];
}

/// <summary>Per-request details about how this site is being served.</summary>
public class SiteInfo
{
    public string DllName { get; set; }
    public string ContentRoot { get; set; }
    public string Environment { get; set; }
    public string Urls { get; set; }
    public string RequestHost { get; set; }
    public string Scheme { get; set; }
    public string ClientIp { get; set; }
    public bool BehindProxy { get; set; }
}

public record CheckPage(HealthReport Report, SiteInfo Site);
