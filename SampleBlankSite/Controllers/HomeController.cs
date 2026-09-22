using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using SampleBlankSite.Models;

namespace SampleBlankSite.Controllers
{
    public class HomeController(ILogger<HomeController> logger, IWebHostEnvironment env) : Controller
    {
        private const int TimeoutMs = 2000; // 2 second timeout for all operations

        public async Task<IActionResult> Index()
        {
            return Content("OK, please visit /check for more details", "text/html");
        }

        [Route("/check")]
        public async Task<IActionResult> Check()
        {
            // Start all tasks concurrently
            var dotNetTask = GetDotNetSdkVersionsAsync();
            var nginxTask = GetNginxStatusAsync();
            var ipAddressTask = GetIpAddressAsync();
            var mongoDbTask = GetMongoDbInfoAsync();
            var mySqlTask = GetMySqlInfoAsync();
            var postgreSqlTask = GetPostgreSqlInfoAsync();
            var sqlServerTask = GetSqlServerInfoAsync();
            var dockerTask = GetDockerInfoAsync();
            var openPortsTask = GetOpenPortsAsync();
            var websiteIpAddressTask = GetWebsiteIpAddressAsync();

            // Wait for all tasks to complete simultaneously
            await Task.WhenAll(
                dotNetTask,
                nginxTask,
                ipAddressTask,
                mongoDbTask,
                mySqlTask,
                postgreSqlTask,
                sqlServerTask,
                dockerTask,
                openPortsTask,
                websiteIpAddressTask
            );

            // Create model with results
            var model = new SystemInfoViewModel
            {
                DotNetSdkVersions = dotNetTask.Result,
                NginxStatus = nginxTask.Result,
                IpAddress = ipAddressTask.Result,
                MongoDbInfo = mongoDbTask.Result,
                MySqlInfo = mySqlTask.Result,
                PostgreSqlInfo = postgreSqlTask.Result,
                SqlServerInfo = sqlServerTask.Result,
                DockerInfo = dockerTask.Result,
                OpenPorts = openPortsTask.Result,
                WebsiteDirectory = env.ContentRootPath,
                WebsiteIpAddress = websiteIpAddressTask.Result
            };

            return View(model);
        }

        private async Task<List<string>> GetDotNetSdkVersionsAsync()
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeoutMs);
                return await RunProcessWithTimeoutAsync("dotnet", "--list-sdks", cts.Token);
            }
            catch (OperationCanceledException)
            {
                logger.LogWarning("Timeout getting .NET SDK versions");
                return ["Timeout getting .NET SDK versions"];
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error getting .NET SDK versions");
                return ["Error getting .NET SDK versions: " + ex.Message];
            }
        }

        private async Task<ServiceStatus> GetNginxStatusAsync()
        {
            var status = new ServiceStatus
            {
                IsInstalled = false,
                IsRunning = false,
                Version = "Not installed",
                ConnectionStatus = "Not available"
            };

            try
            {
                using var cts = new CancellationTokenSource(TimeoutMs);
                var output = await RunProcessWithTimeoutAsync("systemctl", "is-active nginx", cts.Token);

                if (output.Count > 0)
                {
                    status.IsInstalled = true;
                    status.IsRunning = output[0].Trim() == "active";
                    status.ConnectionStatus = output[0].Trim() == "active" ? "Running" : "Not running";

                    try
                    {
                        using var versionCts = new CancellationTokenSource(TimeoutMs);
                        var versionOutput = await RunProcessWithTimeoutAsync("nginx", "-v", versionCts.Token, true);
                        status.Version = versionOutput.Count > 0 ? versionOutput[0].Trim() : "Installed, version unknown";
                    }
                    catch (OperationCanceledException)
                    {
                        status.Version = "Timeout getting version";
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Error getting Nginx version");
                        status.Version = "Installed, version unknown";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                logger.LogWarning("Timeout checking Nginx status");
                status.Version = "Timeout checking status";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error getting Nginx status");
                status.Version = "Error: " + ex.Message;
            }

            return status;
        }

        private async Task<string> GetIpAddressAsync()
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeoutMs);
                var hostName = Dns.GetHostName();
                var hostEntryTask = Dns.GetHostEntryAsync(hostName, cts.Token);

                if (await Task.WhenAny(hostEntryTask, Task.Delay(TimeoutMs, cts.Token)) != hostEntryTask)
                {
                    return "Timeout getting IP address";
                }

                var hostEntry = await hostEntryTask;
                var ipAddress = hostEntry.AddressList
                    .FirstOrDefault(ip => ip.AddressFamily == AddressFamily.InterNetwork);
                return ipAddress?.ToString() ?? "Not available";
            }
            catch (OperationCanceledException)
            {
                return "Timeout getting IP address";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error getting IP address");
                return "Error: " + ex.Message;
            }
        }

        private Task<ServiceStatus> GetMongoDbInfoAsync() =>
            GetDatabaseInfoAsync("MongoDB", 27017, "mongod", "--version", l => l.Contains("db version"));

        private Task<ServiceStatus> GetMySqlInfoAsync() =>
            GetDatabaseInfoAsync("MySQL", 3306, "mysql", "--version");

        private Task<ServiceStatus> GetPostgreSqlInfoAsync() =>
            GetDatabaseInfoAsync("PostgreSQL", 5432, "psql", "--version");

        private Task<ServiceStatus> GetSqlServerInfoAsync() =>
            GetDatabaseInfoAsync("SQL Server", 1433, "sqlcmd", "-?", _ => false);

        // Shared DB check: probe the default port (no driver needed), then ask the
        // CLI tool for a version string if it is installed.
        private async Task<ServiceStatus> GetDatabaseInfoAsync(
            string name, int port, string cliFileName, string cliArguments, Func<string, bool> versionLineFilter = null)
        {
            var status = new ServiceStatus
            {
                IsInstalled = false,
                IsRunning = false,
                Version = "Not installed",
                ConnectionStatus = "Not available"
            };

            try
            {
                using var probeCts = new CancellationTokenSource(TimeoutMs);
                (status.IsRunning, status.ConnectionStatus) = await ProbeTcpPortAsync(port, probeCts.Token);
                if (status.IsRunning)
                {
                    status.IsInstalled = true;
                    status.Version = $"Listening on {port}";
                }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error probing {Name} port {Port}", name, port);
                status.ConnectionStatus = "Error: " + ex.Message;
            }

            try
            {
                using var cts = new CancellationTokenSource(TimeoutMs);
                var output = await RunProcessWithTimeoutAsync(cliFileName, cliArguments, cts.Token);

                if (output.Count > 0)
                {
                    status.IsInstalled = true;
                    var versionLine = versionLineFilter == null ? output[0] : output.FirstOrDefault(versionLineFilter);
                    if (versionLine != null)
                    {
                        status.Version = versionLine.Trim();
                    }
                    else if (!status.IsRunning)
                    {
                        status.Version = "Installed, version unknown";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                status.Version = "Timeout checking installation";
            }
            catch (Exception ex)
            {
                // CLI not on PATH is the normal case when the DB isn't installed
                logger.LogDebug(ex, "{Name} CLI '{Cli}' not available", name, cliFileName);
            }

            return status;
        }

        private async Task<ServiceStatus> GetDockerInfoAsync()
        {
            var status = new ServiceStatus
            {
                IsInstalled = false,
                IsRunning = false,
                Version = "Not installed",
                ConnectionStatus = "Not available"
            };

            try
            {
                using var cts = new CancellationTokenSource(TimeoutMs);
                var output = await RunProcessWithTimeoutAsync("docker", "--version", cts.Token);

                if (output.Count > 0)
                {
                    status.IsInstalled = true;
                    status.Version = output[0].Trim();

                    try
                    {
                        using var infoCts = new CancellationTokenSource(TimeoutMs);
                        var infoResult = await RunProcessWithExitCodeAsync("docker", "info", infoCts.Token);
                        status.IsRunning = infoResult.ExitCode == 0;
                        status.ConnectionStatus = status.IsRunning ? "Running" : "Not running";
                    }
                    catch (OperationCanceledException)
                    {
                        status.ConnectionStatus = "Timeout checking status";
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Error checking Docker status");
                        status.ConnectionStatus = "Error checking status";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                status.Version = "Timeout checking installation";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error checking Docker installation");
                status.Version = "Error: " + ex.Message;
            }

            return status;
        }

        private async Task<List<string>> GetOpenPortsAsync()
        {
            try
            {
                var result = new List<string>();
                using var cts = new CancellationTokenSource(TimeoutMs);

                if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
                {
                    // Try ss command first
                    try
                    {
                        var output = await RunProcessWithTimeoutAsync("ss", "-tuln", cts.Token);
                        if (output.Count > 0)
                        {
                            foreach (var line in output.Skip(1)) // Skip header
                            {
                                var parts = line.Split([' '], StringSplitOptions.RemoveEmptyEntries);
                                if (parts.Length >= 5)
                                {
                                    var addressPart = parts[4];
                                    if (addressPart.Contains(":"))
                                    {
                                        var port = addressPart.Split(':').Last();
                                        result.Add(port);
                                    }
                                }
                            }
                            return result.Distinct().OrderBy(int.Parse).ToList();
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        // Timeout on ss, try netstat
                    }
                    catch
                    {
                        // Error on ss, try netstat
                    }

                    // Try netstat if ss fails
                    try
                    {
                        using var netstatCts = new CancellationTokenSource(TimeoutMs);
                        var output = await RunProcessWithTimeoutAsync("netstat", "-tuln", netstatCts.Token);

                        if (output.Count > 0)
                        {
                            foreach (var line in output.Skip(2)) // Skip headers
                            {
                                var parts = line.Trim().Split([' '], StringSplitOptions.RemoveEmptyEntries);
                                if (parts.Length >= 4)
                                {
                                    var addressPart = parts[3];
                                    if (addressPart.Contains(":"))
                                    {
                                        var port = addressPart.Split(':').Last();
                                        result.Add(port);
                                    }
                                }
                            }
                            return result.Distinct().OrderBy(int.Parse).ToList();
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        // Timeout on netstat, fall back to .NET
                    }
                    catch
                    {
                        // Error on netstat, fall back to .NET
                    }
                }

                // For non-Linux platforms or if Linux commands failed, use .NET
                var properties = IPGlobalProperties.GetIPGlobalProperties();
                var activeTcpListeners = properties.GetActiveTcpListeners();
                foreach (var endpoint in activeTcpListeners)
                {
                    result.Add(endpoint.Port.ToString());
                }

                return result.Distinct().OrderBy(int.Parse).ToList();
            }
            catch (OperationCanceledException)
            {
                return ["Timeout getting open ports"];
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error getting open ports");
                return ["Error: " + ex.Message];
            }
        }

        private async Task<string> GetWebsiteIpAddressAsync()
        {
            try
            {
                using var cts = new CancellationTokenSource(TimeoutMs);
                var hostTask = Dns.GetHostEntryAsync(Dns.GetHostName(), cts.Token);

                if (await Task.WhenAny(hostTask, Task.Delay(TimeoutMs, cts.Token)) != hostTask)
                {
                    return "Timeout getting website IP address";
                }

                var host = await hostTask;
                foreach (var ip in host.AddressList)
                {
                    if (ip.AddressFamily == AddressFamily.InterNetwork)
                    {
                        return ip.ToString();
                    }
                }
                return "No network adapters with an IPv4 address found";
            }
            catch (OperationCanceledException)
            {
                return "Timeout getting website IP address";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error getting website IP address");
                return "Error: " + ex.Message;
            }
        }

        // Helper method to probe a local TCP port with timeout (no DB driver needed)
        private static async Task<(bool Open, string Status)> ProbeTcpPortAsync(int port, CancellationToken cancellationToken)
        {
            using var client = new TcpClient();
            try
            {
                await client.ConnectAsync(IPAddress.Loopback, port, cancellationToken);
                return (true, $"Port {port} open");
            }
            catch (OperationCanceledException)
            {
                return (false, "Connection timeout");
            }
            catch (SocketException)
            {
                return (false, $"Port {port} closed");
            }
        }

        // Helper method to run a process with timeout and capture output
        private async Task<List<string>> RunProcessWithTimeoutAsync(string fileName, string arguments, CancellationToken cancellationToken, bool captureError = false)
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    RedirectStandardOutput = true,
                    RedirectStandardError = captureError,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            List<string> output;

            try
            {
                process.Start();

                // Choose which stream to read based on captureError flag
                var streamReader = captureError ? process.StandardError : process.StandardOutput;

                // Read output with timeout
                using var readCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                var readTask = ReadStreamToEndAsync(streamReader, readCts.Token);

                // Wait for process to exit with timeout
                var waitTask = process.WaitForExitAsync(cancellationToken);

                // Wait for both tasks to complete or timeout
                await Task.WhenAll(readTask, waitTask);

                var outputText = await readTask;
                output = outputText
                    .Split([Environment.NewLine], StringSplitOptions.RemoveEmptyEntries)
                    .ToList();
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(); } catch { /* Ignore if already exited */ }
                throw; // Re-throw to handle timeout in caller
            }
            catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 2)
            {
                // Binary not on PATH: report "nothing found" rather than an error
                logger.LogDebug("Process {FileName} not found", fileName);
                output = [];
            }
            catch (Exception ex)
            {
                logger.LogError(ex, $"Error running process {fileName} {arguments}");
                throw;
            }
            finally
            {
                // HasExited throws if Start() failed (e.g. binary not on PATH)
                try { if (!process.HasExited) process.Kill(); } catch { /* Ignore if not started or already exited */ }
                process.Dispose();
            }

            return output;
        }

        // Helper method to read from a StreamReader with cancellation support
        private async Task<string> ReadStreamToEndAsync(StreamReader reader, CancellationToken cancellationToken)
        {
            var output = new System.Text.StringBuilder();

            // Use simple ReadToEndAsync with cancellation registration
            try
            {
                cancellationToken.ThrowIfCancellationRequested();

                // Register a cancellation callback to throw on the reader's task
                await using var registration = cancellationToken.Register(() => {
                    try
                    {
                        // This will cause ReadToEndAsync to throw on cancellation
                        reader.Close();
                    }
                    catch { /* Ignore any errors here */ }
                });

                // Read all text
                var content = await reader.ReadToEndAsync(cancellationToken);
                output.Append(content);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex) when (cancellationToken.IsCancellationRequested)
            {
                // Convert other exceptions to OperationCanceledException if we requested cancellation
                throw new OperationCanceledException("Reading from stream was canceled", ex, cancellationToken);
            }

            return output.ToString();
        }
        // Helper method to run a process with timeout and capture exit code
        private async Task<(int ExitCode, List<string> Output)> RunProcessWithExitCodeAsync(string fileName, string arguments, CancellationToken cancellationToken)
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            try
            {
                process.Start();

                // Read output with timeout
                using var readCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                var readTask = ReadStreamToEndAsync(process.StandardOutput, readCts.Token);

                // Wait for process to exit with timeout
                var waitTask = process.WaitForExitAsync(cancellationToken);

                // Wait for both tasks to complete or timeout
                await Task.WhenAll(readTask, waitTask);

                var outputText = await readTask;
                var output = outputText
                    .Split([Environment.NewLine], StringSplitOptions.RemoveEmptyEntries)
                    .ToList();

                return (process.ExitCode, output);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(); } catch { /* Ignore if already exited */ }
                throw; // Re-throw to handle timeout in caller
            }
            catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 2)
            {
                // Binary not on PATH: report "nothing found" rather than an error
                logger.LogDebug("Process {FileName} not found", fileName);
                return (-1, []);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, $"Error running process {fileName} {arguments}");
                throw;
            }
            finally
            {
                // HasExited throws if Start() failed (e.g. binary not on PATH)
                try { if (!process.HasExited) process.Kill(); } catch { /* Ignore if not started or already exited */ }
                process.Dispose();
            }
        }
    }
}