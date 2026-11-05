using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using SampleBlankSite.Models;

namespace SampleBlankSite.Services;

/// <summary>
/// Collects a snapshot of server health. Linux data comes from /proc, /sys, /etc and a few
/// read-only commands that work as an unprivileged user (www-data). On other platforms the
/// Linux-only sections are left empty instead of failing.
/// </summary>
public sealed partial class HealthProbe(ProcessRunner runner, ILogger<HealthProbe> logger)
{
    private static readonly bool IsLinux = RuntimeInformation.IsOSPlatform(OSPlatform.Linux);

    // Results are reused briefly so a page left on auto-refresh (or several viewers)
    // doesn't spawn a burst of processes on every request.
    private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(5);
    private readonly Lock _gate = new();
    private Task<HealthReport> _current;
    private DateTimeOffset _startedAt;

    private sealed record ServiceSpec(string Name, string[] Units, int? Port, string VersionCmd, string VersionArgs);

    // Mirrors the tools NsPanel can install (NsPanel/modules/).
    private static readonly ServiceSpec[] KnownServices =
    [
        new("Nginx", ["nginx"], 80, "nginx", "-v"),
        new("MariaDB / MySQL", ["mariadb", "mysql"], 3306, "mysql", "--version"),
        new("PostgreSQL", ["postgresql"], 5432, "psql", "--version"),
        new("MongoDB", ["mongod"], 27017, "mongod", "--version"),
        new("SQL Server", ["mssql-server"], 1433, null, null),
        new("Redis", ["redis-server", "redis"], 6379, "redis-server", "--version"),
        new("RabbitMQ", ["rabbitmq-server"], 5672, null, null),
        new("Elasticsearch", ["elasticsearch"], 9200, null, null),
        new("Kibana", ["kibana"], 5601, null, null),
        new("OpenObserve", ["openobserve"], 5080, null, null),
        new("Docker", ["docker"], null, "docker", "--version"),
        new("Samba", ["smbd"], 445, "smbd", "--version"),
        new("CoreDNS", ["coredns"], null, "coredns", "-version"),
        new("Cloudflare Tunnel", ["cloudflared"], null, "cloudflared", "--version"),
        new("Fail2ban", ["fail2ban"], null, "fail2ban-client", "--version"),
        new("UFW", ["ufw"], null, null, null),
    ];

    private static readonly HashSet<string> PseudoFileSystems = new(StringComparer.OrdinalIgnoreCase)
    {
        "tmpfs", "devtmpfs", "overlay", "squashfs", "proc", "sysfs", "cgroup", "cgroup2", "devpts",
        "mqueue", "debugfs", "tracefs", "securityfs", "pstore", "bpf", "fusectl", "configfs",
        "hugetlbfs", "autofs", "binfmt_misc", "efivarfs", "ramfs", "nsfs", "rpc_pipefs",
        "fuse.lxcfs", "fuse.snapfuse", "fuse.gvfsd-fuse", "nfsd", "selinuxfs", "rootfs",
    };

    public Task<HealthReport> GetAsync()
    {
        lock (_gate)
        {
            var now = DateTimeOffset.UtcNow;
            if (_current is { } current && (!current.IsCompleted || now - _startedAt < CacheFor) && !current.IsFaulted)
            {
                return current;
            }
            _startedAt = now;
            _current = CollectAsync();
            return _current;
        }
    }

    private async Task<HealthReport> CollectAsync()
    {
        var sw = Stopwatch.StartNew();
        var report = new HealthReport { GeneratedAt = DateTimeOffset.Now };

        await Task.WhenAll(
            Safe("host", async () => report.Host = await GetHostAsync()),
            Safe("cpu", async () => report.Cpu = await GetCpuAsync()),
            Safe("memory", () => { report.Memory = GetMemory(); return Task.CompletedTask; }),
            Safe("disks", () => { report.Disks = GetDisks(); return Task.CompletedTask; }),
            Safe("network", async () => report.Network = await GetNetworkAsync()),
            Safe("services", async () => report.Services = await GetServicesAsync()),
            Safe("failed units", async () => report.FailedUnits = await GetFailedUnitsAsync()),
            Safe("dotnet", async () => report.DotNet = await GetDotNetAsync()),
            Safe("processes", () => { report.TopProcesses = GetTopProcesses(8); return Task.CompletedTask; }),
            Safe("ports", () => { report.ListeningPorts = GetListeningPorts(); return Task.CompletedTask; }),
            Safe("maintenance", () => { report.Maintenance = GetMaintenance(); return Task.CompletedTask; }));

        Evaluate(report);
        report.CollectMs = sw.Elapsed.TotalMilliseconds;
        return report;
    }

    private async Task Safe(string section, Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Health section '{Section}' failed", section);
        }
    }

    // ── Host ────────────────────────────────────────────────────────────────

    private async Task<HostInfo> GetHostAsync()
    {
        var info = new HostInfo
        {
            Hostname = Environment.MachineName,
            Os = RuntimeInformation.OSDescription,
            Kernel = Environment.OSVersion.VersionString,
            Architecture = RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(),
            Uptime = TimeSpan.FromMilliseconds(Environment.TickCount64),
            ServerTime = DateTimeOffset.Now,
            TimeZone = TimeZoneInfo.Local.Id,
        };

        if (!IsLinux) return info;

        info.Hostname = ReadFirstLine("/proc/sys/kernel/hostname") ?? info.Hostname;
        info.Kernel = ReadFirstLine("/proc/sys/kernel/osrelease") ?? info.Kernel;

        var osRelease = ReadKeyValues("/etc/os-release", '=');
        if (osRelease.TryGetValue("PRETTY_NAME", out var pretty)) info.Os = pretty.Trim('"');

        if (ReadFirstLine("/proc/uptime")?.Split(' ')[0] is { } up &&
            double.TryParse(up, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds))
        {
            info.Uptime = TimeSpan.FromSeconds(seconds);
        }

        var virt = runner.RunAsync("systemd-detect-virt", "");
        var ntp = runner.RunAsync("timedatectl", "show -p NTPSynchronized --value");
        await Task.WhenAll(virt, ntp);

        // systemd-detect-virt exits 1 and prints "none" on bare metal.
        if (virt.Result.Found && !virt.Result.TimedOut) info.Virtualization = virt.Result.FirstLine;
        if (ntp.Result.Ok) info.NtpSynced = ntp.Result.FirstLine == "yes";

        return info;
    }

    // ── CPU ─────────────────────────────────────────────────────────────────

    private static async Task<CpuInfo> GetCpuAsync()
    {
        var info = new CpuInfo { Cores = Environment.ProcessorCount };
        if (!IsLinux) return info;

        var cpuinfo = SafeReadAllLines("/proc/cpuinfo");
        info.Model = ValueOf(cpuinfo, "model name") ?? ValueOf(cpuinfo, "Model") ?? ValueOf(cpuinfo, "Hardware");

        var load = ReadFirstLine("/proc/loadavg")?.Split(' ');
        if (load is { Length: >= 3 })
        {
            info.Load1 = ParseDouble(load[0]);
            info.Load5 = ParseDouble(load[1]);
            info.Load15 = ParseDouble(load[2]);
        }

        // CPU usage = busy share of jiffies between two samples.
        var first = ReadCpuJiffies();
        await Task.Delay(250);
        var second = ReadCpuJiffies();
        if (first is { } a && second is { } b && b.Total > a.Total)
        {
            info.UsagePercent = Math.Clamp(100.0 * (1 - (double)(b.Idle - a.Idle) / (b.Total - a.Total)), 0, 100);
        }

        return info;

        static (long Idle, long Total)? ReadCpuJiffies()
        {
            var line = ReadFirstLine("/proc/stat");
            if (line == null || !line.StartsWith("cpu ")) return null;
            var values = line[4..].Split(' ', StringSplitOptions.RemoveEmptyEntries)
                .Take(8) // user nice system idle iowait irq softirq steal
                .Select(v => long.TryParse(v, out var n) ? n : 0).ToArray();
            if (values.Length < 5) return null;
            return (values[3] + values[4], values.Sum());
        }
    }

    // ── Memory ──────────────────────────────────────────────────────────────

    private static MemoryInfo GetMemory()
    {
        var info = new MemoryInfo();
        if (!IsLinux)
        {
            info.TotalBytes = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes;
            return info;
        }

        var mem = ReadKeyValues("/proc/meminfo", ':');
        info.TotalBytes = Kb(mem, "MemTotal");
        info.AvailableBytes = Kb(mem, "MemAvailable");
        info.SwapTotalBytes = Kb(mem, "SwapTotal");
        info.SwapFreeBytes = Kb(mem, "SwapFree");
        return info;

        static long? Kb(Dictionary<string, string> values, string key) =>
            values.TryGetValue(key, out var raw) && long.TryParse(raw.Split(' ', StringSplitOptions.RemoveEmptyEntries)[0], out var kb)
                ? kb * 1024
                : null;
    }

    // ── Disks ───────────────────────────────────────────────────────────────

    private static List<DiskInfo> GetDisks()
    {
        var disks = new List<DiskInfo>();
        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady) continue;
                var mount = drive.RootDirectory.FullName;
                if (IsLinux)
                {
                    if (PseudoFileSystems.Contains(drive.DriveFormat)) continue;
                    if (mount.StartsWith("/snap/") || mount.StartsWith("/run/") || mount.StartsWith("/var/lib/docker/")) continue;
                }
                else if (drive.DriveType != DriveType.Fixed)
                {
                    continue;
                }
                if (drive.TotalSize <= 0) continue;

                disks.Add(new DiskInfo
                {
                    Mount = mount,
                    FileSystem = drive.DriveFormat,
                    TotalBytes = drive.TotalSize,
                    FreeBytes = drive.AvailableFreeSpace,
                });
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Mount we can't stat as this user: skip it.
            }
        }

        // Bind mounts show the same filesystem several times; keep the shortest path.
        return disks
            .GroupBy(d => (d.TotalBytes, d.FileSystem))
            .Select(g => g.OrderBy(d => d.Mount.Length).First())
            .OrderBy(d => d.Mount, StringComparer.Ordinal)
            .ToList();
    }

    // ── Network ─────────────────────────────────────────────────────────────

    private static async Task<NetworkInfo> GetNetworkAsync()
    {
        var info = new NetworkInfo();

        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            if (nic.Name.StartsWith("veth", StringComparison.Ordinal)) continue;
            // Linux reports tunnels (tailscale0, wg0) as Unknown, so only hide links that are clearly down.
            if (nic.OperationalStatus is OperationalStatus.Down or OperationalStatus.NotPresent or OperationalStatus.LowerLayerDown) continue;

            var addresses = nic.GetIPProperties().UnicastAddresses
                .Where(a => !a.Address.IsIPv6LinkLocal)
                .Select(a => $"{a.Address}/{a.PrefixLength}")
                .ToList();

            var mac = nic.GetPhysicalAddress().GetAddressBytes();
            info.Interfaces.Add(new InterfaceEntry
            {
                Name = nic.Name,
                Status = nic.OperationalStatus.ToString(),
                Mac = mac.Length == 0 ? null : string.Join(":", mac.Select(b => b.ToString("x2"))),
                Addresses = addresses,
            });
        }

        var internet = ProbeAsync(new IPEndPoint(IPAddress.Parse("1.1.1.1"), 443), TimeSpan.FromSeconds(2));
        var dns = ResolveAsync("github.com", TimeSpan.FromSeconds(2));
        await Task.WhenAll(internet, dns);

        (info.InternetReachable, info.InternetLatencyMs) = internet.Result;
        (info.DnsWorks, info.DnsDetail) = dns.Result;
        return info;

        static async Task<(bool, string)> ResolveAsync(string host, TimeSpan timeout)
        {
            try
            {
                using var cts = new CancellationTokenSource(timeout);
                var addresses = await Dns.GetHostAddressesAsync(host, cts.Token);
                return addresses.Length > 0
                    ? (true, $"{host} → {addresses[0]}")
                    : (false, $"{host} returned no address");
            }
            catch (OperationCanceledException)
            {
                return (false, $"{host}: timeout");
            }
            catch (SocketException ex)
            {
                return (false, $"{host}: {ex.SocketErrorCode}");
            }
        }
    }

    /// <summary>TCP connect test. Returns (open, latency in ms).</summary>
    private static async Task<(bool Open, double? LatencyMs)> ProbeAsync(IPEndPoint endpoint, TimeSpan timeout)
    {
        using var client = new TcpClient(endpoint.AddressFamily);
        using var cts = new CancellationTokenSource(timeout);
        var sw = Stopwatch.StartNew();
        try
        {
            await client.ConnectAsync(endpoint, cts.Token);
            return (true, Math.Round(sw.Elapsed.TotalMilliseconds, 1));
        }
        catch (Exception ex) when (ex is OperationCanceledException or SocketException)
        {
            return (false, null);
        }
    }

    // ── Services ────────────────────────────────────────────────────────────

    private async Task<List<ServiceStatus>> GetServicesAsync()
    {
        if (!IsLinux) return [];
        var results = await Task.WhenAll(KnownServices.Select(GetServiceAsync));
        return results.ToList();
    }

    private async Task<ServiceStatus> GetServiceAsync(ServiceSpec spec)
    {
        var status = new ServiceStatus { Name = spec.Name, Unit = spec.Units[0], Port = spec.Port };

        foreach (var unit in spec.Units)
        {
            var show = await runner.RunAsync("systemctl", $"show {unit} --property=LoadState,ActiveState");
            if (!show.Ok) continue;
            var props = show.Lines.Select(l => l.Split('=', 2)).Where(p => p.Length == 2).ToDictionary(p => p[0], p => p[1]);
            if (props.GetValueOrDefault("LoadState") != "loaded") continue;

            status.Unit = unit;
            status.IsInstalled = true;
            status.ActiveState = props.GetValueOrDefault("ActiveState");
            break;
        }

        var versionTask = spec.VersionCmd != null
            ? runner.RunAsync(spec.VersionCmd, spec.VersionArgs)
            : Task.FromResult(ProcessResult.NotFound);
        var portTask = status.IsInstalled && spec.Port is { } port
            ? ProbeAsync(new IPEndPoint(IPAddress.Loopback, port), TimeSpan.FromSeconds(1))
            : Task.FromResult<(bool, double?)>((false, null));
        await Task.WhenAll(versionTask, portTask);

        var version = versionTask.Result;
        if (version.Found && !version.TimedOut && version.FirstLine is { Length: > 0 } line)
        {
            status.IsInstalled = true;
            status.Version = line.Length > 80 ? line[..80] + "…" : line;
        }
        if (status.IsInstalled && spec.Port != null) status.PortOpen = portTask.Result.Item1;

        return status;
    }

    private async Task<List<string>> GetFailedUnitsAsync()
    {
        if (!IsLinux) return [];
        var result = await runner.RunAsync("systemctl", "--failed --no-legend --plain --no-pager");
        return result.Ok
            ? result.Lines.Select(l => l.Split(' ', 2)[0]).Where(u => u.Length > 0).ToList()
            : [];
    }

    // ── .NET ────────────────────────────────────────────────────────────────

    private async Task<DotNetInfo> GetDotNetAsync()
    {
        using var self = Process.GetCurrentProcess();
        var info = new DotNetInfo
        {
            AppRuntime = RuntimeInformation.FrameworkDescription,
            ProcessId = Environment.ProcessId,
            ProcessUser = Environment.UserName,
            WorkingSetBytes = self.WorkingSet64,
            ManagedHeapBytes = GC.GetTotalMemory(false),
            ThreadCount = self.Threads.Count,
            ProcessUptime = DateTime.Now - self.StartTime,
        };

        var sdks = runner.RunAsync("dotnet", "--list-sdks");
        var runtimes = runner.RunAsync("dotnet", "--list-runtimes");
        await Task.WhenAll(sdks, runtimes);

        info.Sdks = StripPaths(sdks.Result);
        info.Runtimes = StripPaths(runtimes.Result);
        return info;

        // "8.0.100 [/usr/lib/dotnet/sdk]" → "8.0.100"
        static List<string> StripPaths(ProcessResult result) =>
            result.Ok ? result.Lines.Select(l => l.Split(" [", 2)[0]).ToList() : [];
    }

    // ── Processes ───────────────────────────────────────────────────────────

    private static List<ProcessEntry> GetTopProcesses(int count)
    {
        var entries = new List<ProcessEntry>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    var memory = process.WorkingSet64;
                    if (memory > 0) entries.Add(new ProcessEntry(process.ProcessName, 1, memory));
                }
                catch
                {
                    // Process exited or is not readable by this user.
                }
            }
        }

        // Group same-named workers (php-fpm, nginx, postgres...) so one service doesn't fill the list.
        return entries
            .GroupBy(e => e.Name)
            .Select(g => new ProcessEntry(g.Key, g.Count(), g.Sum(e => e.MemoryBytes)))
            .OrderByDescending(e => e.MemoryBytes)
            .Take(count)
            .ToList();
    }

    // ── Listening ports ─────────────────────────────────────────────────────

    private static List<ListeningPort> GetListeningPorts()
    {
        var sockets = new List<(int Port, IPAddress Address)>();

        if (IsLinux)
        {
            ParseProcNetTcp("/proc/net/tcp", sockets);
            ParseProcNetTcp("/proc/net/tcp6", sockets);
        }
        else
        {
            sockets.AddRange(IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Select(e => (e.Port, e.Address)));
        }

        return sockets
            .GroupBy(s => s.Port)
            .Select(g => new ListeningPort(
                g.Key,
                g.All(s => IPAddress.IsLoopback(s.Address)),
                string.Join(", ", g.Select(s => s.Address.ToString()).Distinct())))
            .OrderBy(p => p.Port)
            .ToList();
    }

    // Format: "  0: 0100007F:0035 00000000:0000 0A ..." — hex little-endian address, hex port, state 0A = LISTEN.
    private static void ParseProcNetTcp(string path, List<(int, IPAddress)> sockets)
    {
        foreach (var line in SafeReadAllLines(path).Skip(1))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 4 || parts[3] != "0A") continue;

            var local = parts[1].Split(':');
            if (local.Length != 2 || !int.TryParse(local[1], NumberStyles.HexNumber, null, out var port)) continue;

            var hex = local[0];
            var bytes = Convert.FromHexString(hex);
            // Each 32-bit word is stored in host (little-endian) order.
            for (var i = 0; i < bytes.Length; i += 4) Array.Reverse(bytes, i, 4);
            sockets.Add((port, new IPAddress(bytes)));
        }
    }

    // ── Maintenance ─────────────────────────────────────────────────────────

    private static MaintenanceInfo GetMaintenance()
    {
        var info = new MaintenanceInfo();
        if (!IsLinux) return info;

        info.RebootRequired = File.Exists("/var/run/reboot-required");
        info.RebootPackages = SafeReadAllLines("/var/run/reboot-required.pkgs").Distinct().ToList();

        // Written by update-notifier-common on Ubuntu (refreshed by apt's daily timer).
        var notes = SafeReadAllLines("/var/lib/update-notifier/updates-available")
            .Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        info.UpdateNotes = notes;
        foreach (var note in notes)
        {
            if (UpdatesRegex().Match(note) is { Success: true } u) info.PendingUpdates = int.Parse(u.Groups[1].Value);
            if (SecurityRegex().Match(note) is { Success: true } s) info.SecurityUpdates = int.Parse(s.Groups[1].Value);
        }
        if (notes.Count > 0)
        {
            info.PendingUpdates ??= 0;
            info.SecurityUpdates ??= 0;
        }

        return info;
    }

    [GeneratedRegex(@"^(\d+) updates? can be applied")]
    private static partial Regex UpdatesRegex();

    [GeneratedRegex(@"^(\d+) (?:of these updates are|of these updates is a|updates? (?:are|is)) (?:standard )?security update")]
    private static partial Regex SecurityRegex();

    // ── Evaluation ──────────────────────────────────────────────────────────

    private static void Evaluate(HealthReport r)
    {
        var issues = r.Issues;

        if (r.Cpu.UsagePercent >= 90) issues.Add(new(HealthLevel.Warn, "CPU", $"CPU usage is {Format.Percent(r.Cpu.UsagePercent)}"));
        if (r.Cpu.Load5 is { } load && r.Cpu.Cores > 0)
        {
            if (load > r.Cpu.Cores * 2) issues.Add(new(HealthLevel.Critical, "CPU", $"5-min load {load:0.00} is more than twice the {r.Cpu.Cores} cores"));
            else if (load > r.Cpu.Cores) issues.Add(new(HealthLevel.Warn, "CPU", $"5-min load {load:0.00} exceeds {r.Cpu.Cores} cores"));
        }

        var memLevel = Format.Usage(r.Memory.UsedPercent, 90, 95);
        if (memLevel >= HealthLevel.Warn)
            issues.Add(new(memLevel, "Memory", $"Memory {Format.Percent(r.Memory.UsedPercent)} used, {Format.Bytes(r.Memory.AvailableBytes)} available"));
        if (r.Memory.SwapUsedPercent >= 80)
            issues.Add(new(HealthLevel.Warn, "Memory", $"Swap {Format.Percent(r.Memory.SwapUsedPercent)} used"));
        if (r.Memory.SwapTotalBytes == 0 && r.Memory.TotalBytes < 4L * 1024 * 1024 * 1024)
            issues.Add(new(HealthLevel.Info, "Memory", "No swap configured on a host with less than 4 GB RAM"));

        foreach (var disk in r.Disks)
        {
            var level = Format.Usage(disk.UsedPercent);
            if (level >= HealthLevel.Warn)
                issues.Add(new(level, "Disk", $"{disk.Mount} is {Format.Percent(disk.UsedPercent)} full ({Format.Bytes(disk.FreeBytes)} free)"));
        }

        if (r.Network.InternetReachable == false) issues.Add(new(HealthLevel.Critical, "Network", "No outbound internet (TCP 1.1.1.1:443 failed)"));
        if (r.Network.DnsWorks == false) issues.Add(new(HealthLevel.Critical, "Network", $"DNS resolution failed ({r.Network.DnsDetail})"));
        if (r.Host.NtpSynced == false) issues.Add(new(HealthLevel.Warn, "Time", "System clock is not NTP-synchronised"));

        if (r.FailedUnits.Count > 0)
            issues.Add(new(HealthLevel.Critical, "systemd", $"{r.FailedUnits.Count} failed unit(s): {string.Join(", ", r.FailedUnits.Take(5))}"));

        foreach (var s in r.Services.Where(s => s.IsInstalled))
        {
            if (s.ActiveState is "inactive" or "failed")
                issues.Add(new(HealthLevel.Warn, "Service", $"{s.Name} is installed but {s.ActiveState}"));
            else if (s.IsRunning && s.PortOpen == false)
                issues.Add(new(HealthLevel.Warn, "Service", $"{s.Name} is running but port {s.Port} is not accepting connections"));
        }
        if (r.Services.FirstOrDefault(s => s.Name == "Nginx") is { IsInstalled: false })
            issues.Add(new(HealthLevel.Warn, "Service", "Nginx is not installed — NsPanel serves sites through it"));

        if (r.Maintenance.RebootRequired == true)
            issues.Add(new(HealthLevel.Warn, "Maintenance", "A reboot is required to finish installing updates"));
        if (r.Maintenance.SecurityUpdates > 0)
            issues.Add(new(HealthLevel.Warn, "Maintenance", $"{r.Maintenance.SecurityUpdates} security update(s) pending"));
        else if (r.Maintenance.PendingUpdates > 0)
            issues.Add(new(HealthLevel.Info, "Maintenance", $"{r.Maintenance.PendingUpdates} package update(s) available"));

        issues.Sort((a, b) => b.Level.CompareTo(a.Level));
        // Info items are hints only; they never change the overall status.
        var worst = issues.Count > 0 ? issues[0].Level : HealthLevel.Ok;
        r.Overall = worst == HealthLevel.Info ? HealthLevel.Ok : worst;
        r.Score = Math.Max(0, 100
            - 25 * issues.Count(i => i.Level == HealthLevel.Critical)
            - 10 * issues.Count(i => i.Level == HealthLevel.Warn)
            - 2 * issues.Count(i => i.Level == HealthLevel.Info));
    }

    // ── File helpers ────────────────────────────────────────────────────────

    private static string ReadFirstLine(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadLines(path).FirstOrDefault()?.Trim() : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static string[] SafeReadAllLines(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllLines(path) : [];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static Dictionary<string, string> ReadKeyValues(string path, char separator)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in SafeReadAllLines(path))
        {
            var idx = line.IndexOf(separator);
            if (idx > 0) result.TryAdd(line[..idx].Trim(), line[(idx + 1)..].Trim());
        }
        return result;
    }

    private static string ValueOf(string[] lines, string key) =>
        lines.Select(l => l.Split(':', 2))
            .FirstOrDefault(p => p.Length == 2 && p[0].Trim() == key)?[1].Trim();

    private static double? ParseDouble(string value) =>
        double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : null;
}
