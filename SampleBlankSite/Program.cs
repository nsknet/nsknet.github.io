using Microsoft.AspNetCore.HttpOverrides;
using SampleBlankSite.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllersWithViews();
builder.Services.AddSingleton<ProcessRunner>();
builder.Services.AddSingleton<HealthProbe>();

// The app runs behind nginx (see NsPanel/scripts/nginx.sh), which sets
// X-Forwarded-For / X-Forwarded-Proto. Loopback proxies are trusted by default.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
});

var app = builder.Build();

app.UseForwardedHeaders();

if (app.Environment.IsDevelopment())
{
    app.UseDeveloperExceptionPage();
}
else
{
    app.UseExceptionHandler("/Home/Error");
}

app.UseRouting();

// Liveness probe: cheap, no system calls.
app.MapGet("/health", () => Results.Text("OK"));

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Home}/{action=Index}/{id?}");

app.Run();
