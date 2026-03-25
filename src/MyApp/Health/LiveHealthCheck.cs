using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace MyApp.Health;

public sealed class LiveHealthCheck : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context,
        CancellationToken cancellationToken = default)
    {
        return Task.FromResult(HealthCheckResult.Healthy("Application is alive."));
    }
}
