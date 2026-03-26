namespace MyApp.Services;

public sealed class StartupStateHostedService : IHostedService
{
    private readonly AppLifetimeState _state;
    private readonly ILogger<StartupStateHostedService> _logger;

    public StartupStateHostedService(AppLifetimeState state, ILogger<StartupStateHostedService> logger)
    {
        _state = state;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Application startup initialization started.");
        await Task.Delay(500, cancellationToken);
        _state.StartupCompleted = true;
        _logger.LogInformation("Application startup initialization completed.");
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation("Application stopping.");
        return Task.CompletedTask;
    }
}
