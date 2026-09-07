using System.Text;
using System.Text.Json;

namespace GptMate.Windows;

internal static class SessionLogInspector
{
    private const int ActivityTailSize = 2 * 1024 * 1024;
    private static readonly (string Pattern, bool Active)[] LifecyclePatterns =
    [
        ("\"type\":\"task_started\"", true),
        ("\"type\":\"task_complete\"", false),
        ("\"type\":\"turn_aborted\"", false)
    ];

    public static SessionLogState? Inspect(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var length = (int)Math.Min(stream.Length, ActivityTailSize);
            stream.Seek(-length, SeekOrigin.End);
            var buffer = new byte[length];
            stream.ReadExactly(buffer);
            var text = Encoding.UTF8.GetString(buffer);

            var latestOffset = -1;
            bool? active = null;
            foreach (var (pattern, patternActive) in LifecyclePatterns)
            {
                var offset = text.LastIndexOf(pattern, StringComparison.Ordinal);
                if (offset > latestOffset)
                {
                    latestOffset = offset;
                    active = patternActive;
                }
            }
            if (active is null) return null;

            return new SessionLogState(active.Value, active.Value ? LatestReasoning(text) : null);
        }
        catch
        {
            return null;
        }
    }

    private static string? LatestReasoning(string text)
    {
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Reverse())
        {
            if (!line.Contains("\"type\":\"agent_reasoning\"", StringComparison.Ordinal)) continue;
            try
            {
                using var document = JsonDocument.Parse(line);
                if (!document.RootElement.TryGetProperty("payload", out var payload) ||
                    !payload.TryGetProperty("text", out var value)) continue;
                var result = value.GetString()?.Replace("**", "", StringComparison.Ordinal).Trim();
                if (string.IsNullOrEmpty(result)) continue;
                return result[..Math.Min(result.Length, 180)];
            }
            catch (JsonException)
            {
                // Ignore a partial first line when reading only the tail.
            }
        }
        return null;
    }
}
