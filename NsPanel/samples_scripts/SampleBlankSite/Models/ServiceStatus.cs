namespace SampleBlankSite.Models;

public class ServiceStatus
{
    public bool IsInstalled { get; set; }
    public bool IsRunning { get; set; }
    public string Version { get; set; }
    public string ConnectionStatus { get; set; }
}