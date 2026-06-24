using System.Collections.Generic;

namespace SampleBlankSite.Models;

public class SystemInfoViewModel
{
    public List<string> DotNetSdkVersions { get; set; }
    public ServiceStatus NginxStatus { get; set; }
    public string IpAddress { get; set; }
    public ServiceStatus MongoDbInfo { get; set; }
    public ServiceStatus MySqlInfo { get; set; }
    public ServiceStatus PostgreSqlInfo { get; set; }
    public ServiceStatus SqlServerInfo { get; set; }
    public ServiceStatus DockerInfo { get; set; }
    public List<string> OpenPorts { get; set; }
    public string WebsiteDirectory { get; set; }
    public string WebsiteIpAddress { get; set; }
}