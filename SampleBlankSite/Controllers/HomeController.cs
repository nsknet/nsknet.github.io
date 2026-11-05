using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Mvc;
using SampleBlankSite.Models;
using SampleBlankSite.Services;

namespace SampleBlankSite.Controllers;

public class HomeController(HealthProbe probe, IWebHostEnvironment env, IServer server) : Controller
{
    public IActionResult Index() => View(BuildSiteInfo());

    [Route("/check")]
    public async Task<IActionResult> Check() =>
        View(new CheckPage(await probe.GetAsync(), BuildSiteInfo()));

    [Route("/check.json")]
    public async Task<IActionResult> CheckJson() =>
        Json(new CheckPage(await probe.GetAsync(), BuildSiteInfo()));

    [Route("/Home/Error")]
    [ResponseCache(Duration = 0, Location = ResponseCacheLocation.None, NoStore = true)]
    public IActionResult Error()
    {
        Response.StatusCode = StatusCodes.Status500InternalServerError;
        ViewData["Path"] = HttpContext.Features.Get<IExceptionHandlerPathFeature>()?.Path;
        return View();
    }

    private SiteInfo BuildSiteInfo()
    {
        var addresses = server.Features.Get<IServerAddressesFeature>()?.Addresses;
        return new SiteInfo
        {
            // After NsPanel renames the published files, this is the DLL systemd starts.
            DllName = Path.GetFileName(typeof(HomeController).Assembly.Location),
            ContentRoot = env.ContentRootPath,
            Environment = env.EnvironmentName,
            Urls = addresses is { Count: > 0 } ? string.Join(", ", addresses) : null,
            RequestHost = Request.Host.Value,
            Scheme = Request.Scheme,
            ClientIp = HttpContext.Connection.RemoteIpAddress?.ToString(),
            // UseForwardedHeaders moves the proxy's original values into X-Original-* headers.
            BehindProxy = Request.Headers.ContainsKey("X-Original-For") || Request.Headers.ContainsKey("X-Forwarded-For"),
        };
    }
}
