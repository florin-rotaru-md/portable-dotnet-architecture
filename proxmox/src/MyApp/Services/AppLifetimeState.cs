namespace MyApp.Services;

public sealed class AppLifetimeState
{
    public volatile bool IsDraining;
    public volatile bool StartupCompleted;
}
