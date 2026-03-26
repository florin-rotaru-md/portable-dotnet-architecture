using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using MyApp.Health;
using MyApp.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.Configure<HostOptions>(options =>
{
    options.ShutdownTimeout = TimeSpan.FromSeconds(60);
});

builder.Services.AddSingleton<AppLifetimeState>();
builder.Services.AddHostedService<StartupStateHostedService>();

builder.Services
    .AddHealthChecks()
    .AddCheck<LiveHealthCheck>("live", tags: new[] { "live" })
    .AddCheck<ReadyHealthCheck>("ready", tags: new[] { "ready" });

var app = builder.Build();

var state = app.Services.GetRequiredService<AppLifetimeState>();
var lifetime = app.Lifetime;

lifetime.ApplicationStopping.Register(() =>
{
    state.IsDraining = true;
});

app.MapHealthChecks("/.well-known/live", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("live")
});

app.MapHealthChecks("/.well-known/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready")
});

app.MapGet("/", (IConfiguration config) =>
{
    var slot = config["SLOT_NAME"] ?? "unknown";
    return Results.Ok(new
    {
        application = "MyApp",
        slot,
        utc = DateTime.UtcNow
    });
});

app.MapGet("/slow", async (HttpContext context) =>
{
    await Task.Delay(TimeSpan.FromSeconds(15), context.RequestAborted);
    return Results.Ok(new { status = "completed", utc = DateTime.UtcNow });
});

app.Run();
