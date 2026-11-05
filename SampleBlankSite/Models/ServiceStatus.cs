namespace SampleBlankSite.Models;

public class ServiceStatus
{
    public string Name { get; set; }

    /// <summary>The systemd unit that matched (or the first candidate when none is loaded).</summary>
    public string Unit { get; set; }

    public bool IsInstalled { get; set; }

    /// <summary>systemd ActiveState: active, inactive, failed, activating, ... or null when unknown.</summary>
    public string ActiveState { get; set; }

    public bool IsRunning => ActiveState == "active";

    public string Version { get; set; }

    /// <summary>Default TCP port probed on loopback, if the service has one.</summary>
    public int? Port { get; set; }

    public bool? PortOpen { get; set; }
}
