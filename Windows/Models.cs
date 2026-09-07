namespace GptMate.Windows;

internal sealed record RateLimitWindow(double UsedPercent, int? WindowDurationMins, DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => 100 - Math.Clamp(UsedPercent, 0, 100);
}

internal sealed record PlanStep(string Step, string Status);

internal sealed record ActiveTask(string ThreadId, string Title, IReadOnlyList<PlanStep> Steps);

internal sealed record SessionLogState(bool Active, string? Activity);

internal sealed record CodexSnapshot(
    RateLimitWindow? Primary,
    RateLimitWindow? Secondary,
    IReadOnlyList<ActiveTask> Tasks);
