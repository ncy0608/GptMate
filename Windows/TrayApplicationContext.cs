namespace GptMate.Windows;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly CodexAppServerClient client = new();
    private readonly NotifyIcon trayIcon;
    private readonly StatusWindow window;
    private readonly System.Windows.Forms.Timer refreshTimer;
    private Icon? currentIcon;
    private IReadOnlyList<ActiveTask> previousTasks = [];
    private bool hasReceivedInitialTasks;

    public TrayApplicationContext()
    {
        currentIcon = QuotaColors.CreateRingIcon(null);
        trayIcon = new NotifyIcon
        {
            Icon = currentIcon,
            Text = "GptMate · 正在连接 Codex…",
            Visible = true
        };
        window = new StatusWindow(client, Exit);
        _ = window.Handle;
        trayIcon.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button == MouseButtons.Left) window.ToggleNearTray();
        };
        trayIcon.ContextMenuStrip = BuildContextMenu();

        client.ConnectionChanged += (connected, message) => OnUi(() =>
        {
            window.SetConnection(connected, message);
            SetTooltip($"GptMate · {message}");
        });
        client.SnapshotChanged += snapshot => OnUi(() => ApplySnapshot(snapshot));

        refreshTimer = new System.Windows.Forms.Timer { Interval = 8_000 };
        refreshTimer.Tick += (_, _) => client.Refresh();
        refreshTimer.Start();
        client.Start();
    }

    private ContextMenuStrip BuildContextMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开 GptMate", null, (_, _) => window.ShowNearTray());
        menu.Items.Add("刷新", null, (_, _) => client.Refresh());
        menu.Items.Add("重连", null, (_, _) => client.Restart());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Exit());
        return menu;
    }

    private void ApplySnapshot(CodexSnapshot snapshot)
    {
        if (hasReceivedInitialTasks)
        {
            var currentIds = snapshot.Tasks.Select(task => task.ThreadId).ToHashSet();
            foreach (var completed in previousTasks.Where(task => !currentIds.Contains(task.ThreadId)))
            {
                trayIcon.ShowBalloonTip(
                    5_000,
                    "Codex 任务完成",
                    completed.Title[..Math.Min(completed.Title.Length, 160)],
                    ToolTipIcon.Info);
            }
        }
        previousTasks = snapshot.Tasks;
        hasReceivedInitialTasks = true;

        var remaining = snapshot.Primary?.RemainingPercent;
        var replacement = QuotaColors.CreateRingIcon(remaining);
        trayIcon.Icon = replacement;
        currentIcon?.Dispose();
        currentIcon = replacement;
        var percent = remaining is null ? "…" : $"{Math.Round(remaining.Value)}%";
        SetTooltip($"GptMate · 任务运行 {snapshot.Tasks.Count} · 剩余 {percent}");
        window.ApplySnapshot(snapshot);
    }

    private void SetTooltip(string text) => trayIcon.Text = text[..Math.Min(text.Length, 63)];

    private void OnUi(Action action)
    {
        if (window.IsHandleCreated) window.BeginInvoke(action);
        else action();
    }

    private void Exit()
    {
        refreshTimer.Stop();
        client.Dispose();
        trayIcon.Visible = false;
        trayIcon.Dispose();
        currentIcon?.Dispose();
        window.Dispose();
        ExitThread();
    }
}
