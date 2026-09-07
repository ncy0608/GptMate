namespace GptMate.Windows;

internal sealed class StatusWindow : Form
{
    private readonly Label connectionLabel;
    private readonly Panel connectionDot;
    private readonly FlowLayoutPanel quotaPanel;
    private readonly Label tasksTitle;
    private readonly FlowLayoutPanel tasksPanel;

    public StatusWindow(CodexAppServerClient client, Action exit)
    {
        Text = "GptMate";
        ClientSize = new Size(390, 520);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Font = new Font("Segoe UI", 9.5f);
        BackColor = Color.FromArgb(248, 249, 251);
        Deactivate += (_, _) => Hide();
        FormClosing += (_, eventArgs) =>
        {
            if (eventArgs.CloseReason == CloseReason.UserClosing)
            {
                eventArgs.Cancel = true;
                Hide();
            }
        };

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(18),
            ColumnCount = 1,
            RowCount = 6
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 65));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 1));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 170));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 1));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
        Controls.Add(root);

        var header = new Panel { Dock = DockStyle.Fill };
        header.Controls.Add(new Label
        {
            Text = "GptMate",
            Font = new Font("Segoe UI", 16f, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(0, 1)
        });
        connectionLabel = new Label
        {
            Text = "正在连接 Codex…",
            ForeColor = Color.DimGray,
            AutoSize = true,
            Location = new Point(1, 37)
        };
        header.Controls.Add(connectionLabel);
        connectionDot = new Panel
        {
            Size = new Size(11, 11),
            Location = new Point(335, 14),
            BackColor = Color.FromArgb(255, 159, 10)
        };
        header.Controls.Add(connectionDot);
        root.Controls.Add(header, 0, 0);
        root.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.LightGray }, 0, 1);

        quotaPanel = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(0, 12, 0, 4)
        };
        quotaPanel.Controls.Add(Heading("额度"));
        quotaPanel.Controls.Add(new Label { Text = "暂未读取到额度", ForeColor = Color.DimGray, AutoSize = true });
        root.Controls.Add(quotaPanel, 0, 2);
        root.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = Color.LightGray }, 0, 3);

        var taskArea = new Panel { Dock = DockStyle.Fill, Padding = new Padding(0, 12, 0, 0) };
        tasksTitle = Heading("正在运行 0");
        tasksTitle.Location = new Point(0, 12);
        taskArea.Controls.Add(tasksTitle);
        tasksPanel = new FlowLayoutPanel
        {
            Location = new Point(0, 43),
            Size = new Size(350, 145),
            AutoScroll = true,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false
        };
        tasksPanel.Controls.Add(new Label { Text = "暂无活动任务", ForeColor = Color.DimGray, AutoSize = true });
        taskArea.Controls.Add(tasksPanel);
        root.Controls.Add(taskArea, 0, 4);

        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(0, 8, 0, 0)
        };
        footer.Controls.Add(Button("刷新", (_, _) => client.Refresh()));
        footer.Controls.Add(Button("重连", (_, _) => client.Restart()));
        var spacer = new Label { Width = 159, Height = 28 };
        footer.Controls.Add(spacer);
        footer.Controls.Add(Button("退出", (_, _) => exit()));
        root.Controls.Add(footer, 0, 5);
    }

    public void SetConnection(bool connected, string message)
    {
        connectionLabel.Text = message;
        connectionDot.BackColor = connected ? QuotaColors.Normal : Color.FromArgb(255, 159, 10);
    }

    public void ApplySnapshot(CodexSnapshot snapshot)
    {
        quotaPanel.SuspendLayout();
        quotaPanel.Controls.Clear();
        quotaPanel.Controls.Add(Heading("额度"));
        if (snapshot.Primary is null && snapshot.Secondary is null)
            quotaPanel.Controls.Add(new Label { Text = "暂未读取到额度", ForeColor = Color.DimGray, AutoSize = true });
        if (snapshot.Primary is not null) quotaPanel.Controls.Add(CreateQuotaRow(snapshot.Primary, "Codex"));
        if (snapshot.Secondary is not null) quotaPanel.Controls.Add(CreateQuotaRow(snapshot.Secondary, "次级额度"));
        quotaPanel.ResumeLayout();

        tasksTitle.Text = $"正在运行 {snapshot.Tasks.Count}";
        tasksPanel.SuspendLayout();
        tasksPanel.Controls.Clear();
        if (snapshot.Tasks.Count == 0)
            tasksPanel.Controls.Add(new Label { Text = "暂无活动任务", ForeColor = Color.DimGray, AutoSize = true });
        foreach (var task in snapshot.Tasks.Take(5)) tasksPanel.Controls.Add(CreateTaskRow(task));
        tasksPanel.ResumeLayout();
    }

    public void ToggleNearTray()
    {
        if (Visible) Hide(); else ShowNearTray();
    }

    public void ShowNearTray()
    {
        var area = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1920, 1080);
        Location = new Point(area.Right - Width - 12, area.Bottom - Height - 12);
        Show();
        Activate();
    }

    private static Control CreateQuotaRow(RateLimitWindow limit, string fallback)
    {
        var panel = new Panel { Width = 350, Height = 61, Margin = new Padding(0, 4, 0, 0) };
        panel.Controls.Add(new Label { Text = LimitName(limit, fallback), AutoSize = true, Location = new Point(0, 0) });
        var remaining = Math.Round(limit.RemainingPercent);
        panel.Controls.Add(new Label
        {
            Text = $"剩余 {remaining}%",
            AutoSize = true,
            ForeColor = remaining == 0 ? QuotaColors.Danger : Color.FromArgb(45, 45, 48),
            Location = new Point(280, 0)
        });
        var progress = new QuotaProgressBar
        {
            ValuePercent = limit.RemainingPercent,
            Location = new Point(0, 24),
            Size = new Size(350, 7)
        };
        panel.Controls.Add(progress);
        if (limit.ResetsAt is not null)
        {
            panel.Controls.Add(new Label
            {
                Text = $"重置：{limit.ResetsAt.Value.ToLocalTime():yyyy/M/d HH:mm}",
                ForeColor = Color.DimGray,
                AutoSize = true,
                Location = new Point(0, 39),
                Font = new Font("Segoe UI", 8.5f)
            });
        }
        return panel;
    }

    private static Control CreateTaskRow(ActiveTask task)
    {
        var lines = new List<string> { $"⚡ {task.Title}" };
        lines.AddRange(task.Steps.Take(2).Select(step => $"   {StepMark(step.Status)} {step.Step}"));
        return new Label
        {
            Text = string.Join(Environment.NewLine, lines),
            AutoEllipsis = true,
            Width = 330,
            Height = Math.Min(57, 20 + task.Steps.Take(2).Count() * 17),
            Margin = new Padding(0, 0, 0, 7)
        };
    }

    private static string StepMark(string status) => status switch
    {
        "completed" => "✓",
        "inProgress" => "↻",
        _ => "○"
    };

    private static string LimitName(RateLimitWindow limit, string fallback)
    {
        if (limit.WindowDurationMins is not { } minutes) return fallback;
        if (minutes % 1440 == 0) return $"{minutes / 1440} 天额度";
        if (minutes % 60 == 0) return $"{minutes / 60} 小时额度";
        return $"{minutes} 分钟额度";
    }

    private static Label Heading(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new Font("Segoe UI", 10.5f, FontStyle.Bold)
    };

    private static Button Button(string text, EventHandler handler)
    {
        var button = new Button { Text = text, AutoSize = true, Height = 28, Margin = new Padding(0, 0, 8, 0) };
        button.Click += handler;
        return button;
    }
}

internal sealed class QuotaProgressBar : Control
{
    public double ValuePercent { get; init; }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var track = new SolidBrush(Color.FromArgb(226, 229, 234));
        using var fill = new SolidBrush(QuotaColors.For(ValuePercent));
        eventArgs.Graphics.FillRectangle(track, ClientRectangle);
        eventArgs.Graphics.FillRectangle(fill, new Rectangle(0, 0, (int)(Width * Math.Clamp(ValuePercent, 0, 100) / 100), Height));
    }
}
