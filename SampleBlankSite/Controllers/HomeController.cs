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

        private async Task<ServiceStatus> GetMongoDbInfoAsync()
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
                var output = await RunProcessWithTimeoutAsync("mongod", "--version", cts.Token);

                if (output.Count > 0)
                {
                    status.IsInstalled = true;
                    var versionLine = output
                        .FirstOrDefault(l => l.Contains("db version"));
                    status.Version = versionLine != null ? versionLine.Trim() : "Installed, version unknown";

                    // Try to connect to MongoDB with timeout
                    try
                    {
                        var connectionString = "mongodb://localhost:27017/?connectTimeoutMS=2000&serverSelectionTimeoutMS=2000";
                        var client = new MongoDB.Driver.MongoClient(connectionString);

                        using var connectCts = new CancellationTokenSource(TimeoutMs);
                        var database = client.GetDatabase("admin");
                        var command = new MongoDB.Bson.BsonDocument("ping", 1);

                        var pingTask = database.RunCommandAsync<MongoDB.Bson.BsonDocument>(command, cancellationToken: connectCts.Token);
                        if (await Task.WhenAny(pingTask, Task.Delay(TimeoutMs, connectCts.Token)) == pingTask)
                        {
                            await pingTask; // Get any exceptions
                            status.ConnectionStatus = "Connected";
                            status.IsRunning = true;
                        }
                        else
                        {
                            status.ConnectionStatus = "Connection timeout";
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        status.ConnectionStatus = "Connection timeout";
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Failed to connect to MongoDB");
                        status.ConnectionStatus = "Failed to connect";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                status.Version = "Timeout checking installation";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error checking MongoDB installation");
                status.Version = "Error: " + ex.Message;
            }

            return status;
        }

        private async Task<ServiceStatus> GetMySqlInfoAsync()
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
                var output = await RunProcessWithTimeoutAsync("mysql", "--version", cts.Token);

                if (output.Count > 0)
                {
                    status.IsInstalled = true;
                    status.Version = output[0].Trim();

                    try
                    {
                        // Set connection timeout to 2 seconds
                        var connectionString = "server=localhost;user=root;Connect Timeout=2;";
                        await using var connection = new MySql.Data.MySqlClient.MySqlConnection(connectionString);

                        using var connectCts = new CancellationTokenSource(TimeoutMs);
                        var connectTask = connection.OpenAsync(connectCts.Token);

                        if (await Task.WhenAny(connectTask, Task.Delay(TimeoutMs, connectCts.Token)) == connectTask)
                        {
                            await connectTask; // Get any exceptions
                            status.ConnectionStatus = "Connected";
                            status.IsRunning = true;
                        }
                        else
                        {
                            status.ConnectionStatus = "Connection timeout";
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        status.ConnectionStatus = "Connection timeout";
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Failed to connect to MySQL");
                        status.ConnectionStatus = "Failed to connect";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                status.Version = "Timeout checking installation";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error checking MySQL installation");
                status.Version = "Error: " + ex.Message;
            }

            return status;
        }

        private async Task<ServiceStatus> GetPostgreSqlInfoAsync()
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
                var output = await RunProcessWithTimeoutAsync("psql", "--version", cts.Token);

                if (output.Count > 0)
                {
                    status.IsInstalled = true;
                    status.Version = output[0].Trim();

                    try
                    {
                        // Set connection timeout to 2 seconds
                        var connectionString = "Host=localhost;Username=postgres;Timeout=2;Command Timeout=2;";
                        await using var connection = new Npgsql.NpgsqlConnection(connectionString);

                        using var connectCts = new CancellationTokenSource(TimeoutMs);
                        var connectTask = connection.OpenAsync(connectCts.Token);

                        if (await Task.WhenAny(connectTask, Task.Delay(TimeoutMs, connectCts.Token)) == connectTask)
                        {
                            await connectTask; // Get any exceptions
                            status.ConnectionStatus = "Connected";
                            status.IsRunning = true;
                        }
                        else
                        {
                            status.ConnectionStatus = "Connection timeout";
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        status.ConnectionStatus = "Connection timeout";
                    }
                    catch (Exception ex)
                    {
                        logger.LogWarning(ex, "Failed to connect to PostgreSQL");
                        status.ConnectionStatus = "Failed to connect";
                    }
                }
            }
            catch (OperationCanceledException)
            {
                status.Version = "Timeout checking installation";
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error checking PostgreSQL installation");
                status.Version = "Error: " + ex.Message;
            }

            return status;
        }

        private async Task<ServiceStatus> GetSqlServerInfoAsync()
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
                try
                {
                    // Set connection timeout to 2 seconds
                    var connectionString = "Server=localhost;Trusted_Connection=True;TrustServerCertificate=True;Connect Timeout=2;Command Timeout=2;";
                    await using var connection = new Microsoft.Data.SqlClient.SqlConnection(connectionString);

                    using var connectCts = new CancellationTokenSource(TimeoutMs);
                    var connectTask = connection.OpenAsync(connectCts.Token);

                    if (await Task.WhenAny(connectTask, Task.Delay(TimeoutMs, connectCts.Token)) == connectTask)
                    {
                        await connectTask; // Get any exceptions
                        status.ConnectionStatus = "Connected";
                        status.IsInstalled = true;
                        status.IsRunning = true;

                        await using var command = new Microsoft.Data.SqlClient.SqlCommand("SELECT @@VERSION", connection);
                        command.CommandTimeout = 2; // 2 second timeout

                        using var commandCts = new CancellationTokenSource(TimeoutMs);
                        var versionTask = command.ExecuteScalarAsync(commandCts.Token);

                        if (await Task.WhenAny(versionTask, Task.Delay(TimeoutMs, commandCts.Token)) == versionTask)
                        {
                            var version = await versionTask;
                            status.Version = version?.ToString() ?? "Connected, version unknown";
                        }
                        else
                        {
                            status.Version = "Connected, timeout getting version";
                        }
                    }
                    else
                    {
                        status.ConnectionStatus = "Connection timeout";
                    }
                }
                catch (OperationCanceledException)
                {
                    status.ConnectionStatus = "Connection timeout";
                }
                catch (Exception ex)
                {
                    logger.LogWarning(ex, "Failed to connect to SQL Server");
                    status.ConnectionStatus = "Failed to connect";

                    // Check if the SQL Server command-line tool is available
                    try
                    {
                        using var cts = new CancellationTokenSource(TimeoutMs);
                        var output = await RunProcessWithTimeoutAsync("sqlcmd", "-?", cts.Token);

                        if (output.Count > 0)
                        {
                            status.IsInstalled = true;
                            status.Version = "Installed, version unknown";
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        // Ignore timeout during detection
                    }
                    catch
                    {
                        // Ignore additional errors during detection
                    }
                }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Error checking SQL Server installation");
                status.Version = "Error: " + ex.Message;
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
            catch (Exception ex)
            {
                logger.LogError(ex, $"Error running process {fileName} {arguments}");
                throw;
            }
            finally
            {
                if (!process.HasExited)
                {
                    try { process.Kill(); } catch { /* Ignore if already exited */ }
                }
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
            catch (Exception ex)
            {
                logger.LogError(ex, $"Error running process {fileName} {arguments}");
                throw;
            }
            finally
            {
                if (!process.HasExited)
                {
                    try { process.Kill(); } catch { /* Ignore if already exited */ }
                }
                process.Dispose();
            }
        }
    }
}