using Microsoft.Extensions.Diagnostics.HealthChecks;
using MyApp.Services;

namespace MyApp.Health;

public sealed class ReadyHealthCheck : IHealthCheck
{
    private readonly AppLifetimeState _state;
    private readonly IConfiguration _configuration;

    public ReadyHealthCheck(AppLifetimeState state, IConfiguration configuration)
    {
        _state = state;
        _configuration = configuration;
    }

    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        if (!_state.StartupCompleted)
            return Task.FromResult(HealthCheckResult.Unhealthy("Startup not completed."));

        if (_state.IsDraining)
            return Task.FromResult(HealthCheckResult.Unhealthy("Application is draining."));

        var connectionString = _configuration.GetConnectionString("Main");
        if (string.IsNullOrWhiteSpace(connectionString))
            return Task.FromResult(HealthCheckResult.Unhealthy("Main connection string is missing."));

        return Task.FromResult(HealthCheckResult.Healthy("Application is ready."));
    }
}
