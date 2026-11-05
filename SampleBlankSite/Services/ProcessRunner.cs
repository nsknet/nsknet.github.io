using System.ComponentModel;
using System.Diagnostics;

namespace SampleBlankSite.Services;

public sealed record ProcessResult(bool Found, int ExitCode, string StdOut, string StdErr, bool TimedOut)
{
    public static readonly ProcessResult NotFound = new(false, -1, "", "", false);

    public bool Ok => Found && !TimedOut && ExitCode == 0;

    public string[] Lines => StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    /// <summary>First non-empty line of stdout, falling back to stderr (some tools, e.g. nginx -v, print there).</summary>
    public string FirstLine =>
        (StdOut + "\n" + StdErr).Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault() ?? "";
}

/// <summary>Runs a short-lived command with a hard timeout. Never throws for "binary not installed".</summary>
public sealed class ProcessRunner(ILogger<ProcessRunner> logger)
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(3);

    public async Task<ProcessResult> RunAsync(string fileName, string arguments, TimeSpan? timeout = null)
    {
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        // Stable, parseable output regardless of the host locale.
        process.StartInfo.Environment["LC_ALL"] = "C";

        try
        {
            if (!process.Start())
            {
                return ProcessResult.NotFound;
            }
        }
        catch (Win32Exception)
        {
            // Binary not on PATH (or not executable): the normal "not installed" case.
            return ProcessResult.NotFound;
        }

        using var cts = new CancellationTokenSource(timeout ?? DefaultTimeout);
        var stdout = process.StandardOutput.ReadToEndAsync(cts.Token);
        var stderr = process.StandardError.ReadToEndAsync(cts.Token);

        try
        {
            await process.WaitForExitAsync(cts.Token);
            return new ProcessResult(true, process.ExitCode, await stdout, await stderr, false);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { /* already exited */ }
            logger.LogDebug("Timed out: {File} {Args}", fileName, arguments);
            return new ProcessResult(true, -1, "", "", true);
        }
    }
}
