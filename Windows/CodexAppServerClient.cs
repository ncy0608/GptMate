using System.Diagnostics;
using System.Text.Json;

namespace GptMate.Windows;

internal sealed class CodexAppServerClient : IDisposable
{
    public event Action<bool, string>? ConnectionChanged;
    public event Action<CodexSnapshot>? SnapshotChanged;

    private readonly object gate = new();
    private readonly Dictionary<int, string> requests = [];
    private readonly Dictionary<string, IReadOnlyList<PlanStep>> planSteps = [];
    private Process? process;
    private StreamWriter? input;
    private int nextRequestId = 1;
    private bool shouldRestart;
    private RateLimitWindow? primary;
    private RateLimitWindow? secondary;
    private IReadOnlyList<ActiveTask> tasks = [];

    public void Start()
    {
        shouldRestart = true;
        _ = Task.Run(LaunchAsync);
    }

    public void Stop()
    {
        shouldRestart = false;
        lock (gate)
        {
            try { if (process is { HasExited: false }) process.Kill(); } catch { }
            ClearProcess();
        }
    }

    public void Restart()
    {
        Stop();
        Start();
    }

    public void Refresh()
    {
        lock (gate)
        {
            if (process is not { HasExited: false })
            {
                Start();
                return;
            }
            RequestSnapshot();
        }
    }

    private async Task LaunchAsync()
    {
        lock (gate)
        {
            if (process is { HasExited: false }) return;
        }

        var executable = FindCodexExecutable();
        if (executable is null)
        {
            ConnectionChanged?.Invoke(false, "找不到 Codex CLI");
            return;
        }

        var startInfo = CreateStartInfo(executable);
        var launched = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        launched.Exited += (_, _) => OnExited(launched);
        try
        {
            launched.Start();
            lock (gate)
            {
                process = launched;
                input = launched.StandardInput;
                requests.Clear();
                nextRequestId = 1;
            }
            _ = Task.Run(() => DrainErrorAsync(launched));
            _ = Task.Run(() => ReadOutputAsync(launched));
            SendRequest("initialize", new
            {
                clientInfo = new { name = "gptmate-windows", title = "GptMate", version = "0.3.0" },
                capabilities = new { experimentalApi = true }
            });
        }
        catch (Exception error)
        {
            launched.Dispose();
            ConnectionChanged?.Invoke(false, $"无法启动 Codex：{error.Message}");
        }
        await Task.CompletedTask;
    }

    private static ProcessStartInfo CreateStartInfo(string executable)
    {
        ProcessStartInfo info;
        if (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ||
            executable.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
        {
            info = new ProcessStartInfo(Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe");
            info.ArgumentList.Add("/d");
            info.ArgumentList.Add("/s");
            info.ArgumentList.Add("/c");
            info.ArgumentList.Add($"\"{executable}\" app-server --stdio");
        }
        else
        {
            info = new ProcessStartInfo(executable);
            info.ArgumentList.Add("app-server");
            info.ArgumentList.Add("--stdio");
        }
        info.UseShellExecute = false;
        info.CreateNoWindow = true;
        info.RedirectStandardInput = true;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.StandardInputEncoding = System.Text.Encoding.UTF8;
        info.StandardOutputEncoding = System.Text.Encoding.UTF8;
        return info;
    }

    private static string? FindCodexExecutable()
    {
        var candidates = new List<string?>
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Codex", "resources", "codex.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ChatGPT", "resources", "codex.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "codex.cmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin", "codex.exe")
        };
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(directory.Trim('"'), "codex.exe"));
            candidates.Add(Path.Combine(directory.Trim('"'), "codex.cmd"));
        }
        return candidates.FirstOrDefault(candidate => candidate is not null && File.Exists(candidate));
    }

    private async Task ReadOutputAsync(Process source)
    {
        try
        {
            while (await source.StandardOutput.ReadLineAsync() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    using var message = JsonDocument.Parse(line);
                    HandleMessage(message.RootElement);
                }
                catch (JsonException) { }
            }
        }
        catch { }
    }

    private static async Task DrainErrorAsync(Process source)
    {
        try { await source.StandardError.ReadToEndAsync(); } catch { }
    }

    private void HandleMessage(JsonElement message)
    {
        if (message.TryGetProperty("id", out var idValue) && idValue.TryGetInt32(out var id))
        {
            string? method;
            lock (gate)
            {
                requests.Remove(id, out method);
            }
            if (method is null) return;
            var result = message.TryGetProperty("result", out var resultValue) ? resultValue : default;
            switch (method)
            {
                case "initialize":
                    SendNotification("initialized");
                    ConnectionChanged?.Invoke(true, "已连接 Codex");
                    RequestSnapshot();
                    break;
                case "account/rateLimits/read": ParseRateLimits(result); break;
                case "thread/list": ParseThreads(result); break;
            }
            return;
        }

        if (!message.TryGetProperty("method", out var methodValue)) return;
        var methodName = methodValue.GetString();
        var parameters = message.TryGetProperty("params", out var value) ? value : default;
        switch (methodName)
        {
            case "account/rateLimits/updated": ParseRateLimits(parameters); break;
            case "turn/plan/updated": ParsePlan(parameters); break;
            case "thread/status/changed":
            case "thread/started":
            case "turn/completed": RequestSnapshot(); break;
        }
    }

    private void RequestSnapshot()
    {
        SendRequest("account/rateLimits/read", null);
        SendRequest("thread/list", new { limit = 50, sortKey = "updated_at" });
    }

    private void SendRequest(string method, object? parameters)
    {
        int id;
        lock (gate)
        {
            id = nextRequestId++;
            requests[id] = method;
        }
        Send(new { id, method, @params = parameters });
    }

    private void SendNotification(string method) => Send(new { method });

    private void Send(object message)
    {
        lock (gate)
        {
            try
            {
                input?.WriteLine(JsonSerializer.Serialize(message, JsonOptions));
                input?.Flush();
            }
            catch (Exception error)
            {
                ConnectionChanged?.Invoke(false, $"发送请求失败：{error.Message}");
            }
        }
    }

    private void ParseRateLimits(JsonElement container)
    {
        if (container.ValueKind != JsonValueKind.Object) return;
        JsonElement snapshot;
        if (!container.TryGetProperty("rateLimits", out snapshot) &&
            (!container.TryGetProperty("rateLimitsByLimitId", out var buckets) ||
             !buckets.TryGetProperty("codex", out snapshot))) return;
        primary = snapshot.TryGetProperty("primary", out var primaryValue) ? ParseWindow(primaryValue) : null;
        secondary = snapshot.TryGetProperty("secondary", out var secondaryValue) ? ParseWindow(secondaryValue) : null;
        PublishSnapshot();
    }

    private static RateLimitWindow? ParseWindow(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object ||
            !value.TryGetProperty("usedPercent", out var used) ||
            !used.TryGetDouble(out var usedPercent)) return null;
        int? duration = value.TryGetProperty("windowDurationMins", out var durationValue) && durationValue.TryGetInt32(out var minutes)
            ? minutes : null;
        DateTimeOffset? reset = value.TryGetProperty("resetsAt", out var resetValue) && resetValue.TryGetDouble(out var timestamp)
            ? DateTimeOffset.FromUnixTimeSeconds((long)timestamp) : null;
        return new RateLimitWindow(usedPercent, duration, reset);
    }

    private void ParseThreads(JsonElement result)
    {
        if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("data", out var data) ||
            data.ValueKind != JsonValueKind.Array) return;
        var found = new List<ActiveTask>();
        foreach (var thread in data.EnumerateArray().Take(20))
        {
            if (!thread.TryGetProperty("id", out var idValue)) continue;
            var id = idValue.GetString();
            if (string.IsNullOrEmpty(id)) continue;
            var name = GetString(thread, "name");
            var preview = GetString(thread, "preview");
            var title = !string.IsNullOrWhiteSpace(name) ? name : !string.IsNullOrWhiteSpace(preview) ? preview : "未命名任务";
            var statusType = thread.TryGetProperty("status", out var status) ? GetString(status, "type") : null;
            var log = GetString(thread, "path") is { Length: > 0 } path ? SessionLogInspector.Inspect(path) : null;
            if (statusType != "active" && log?.Active != true) continue;
            var steps = planSteps.TryGetValue(id, out var planned) ? planned : [];
            if (steps.Count == 0 && !string.IsNullOrEmpty(log?.Activity))
                steps = [new PlanStep(log.Activity, "inProgress")];
            found.Add(new ActiveTask(id, title!, steps));
        }
        tasks = found;
        PublishSnapshot();
    }

    private void ParsePlan(JsonElement parameters)
    {
        var threadId = GetString(parameters, "threadId");
        if (string.IsNullOrEmpty(threadId) || !parameters.TryGetProperty("plan", out var plan) ||
            plan.ValueKind != JsonValueKind.Array) return;
        planSteps[threadId] = plan.EnumerateArray()
            .Select(item => new PlanStep(GetString(item, "step") ?? "", GetString(item, "status") ?? ""))
            .Where(item => item.Step.Length > 0)
            .ToList();
    }

    private static string? GetString(JsonElement value, string property) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(property, out var result)
            ? result.GetString()?.Trim() : null;

    private void PublishSnapshot() => SnapshotChanged?.Invoke(new CodexSnapshot(primary, secondary, tasks));

    private async void OnExited(Process exited)
    {
        if (!ReferenceEquals(process, exited)) return;
        var code = exited.ExitCode;
        lock (gate) ClearProcess();
        ConnectionChanged?.Invoke(false, $"Codex 连接已断开（{code}）");
        if (!shouldRestart) return;
        await Task.Delay(TimeSpan.FromSeconds(3));
        if (shouldRestart) await LaunchAsync();
    }

    private void ClearProcess()
    {
        input?.Dispose();
        input = null;
        process?.Dispose();
        process = null;
    }

    public void Dispose()
    {
        Stop();
        GC.SuppressFinalize(this);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull
    };
}
