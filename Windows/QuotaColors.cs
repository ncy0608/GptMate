using System.Drawing.Drawing2D;

namespace GptMate.Windows;

internal static class QuotaColors
{
    public static readonly Color Normal = Color.FromArgb(0x28, 0xCD, 0x41);
    public static readonly Color Warning = Color.FromArgb(0xFF, 0xCC, 0x00);
    public static readonly Color Danger = Color.FromArgb(0xFF, 0x3B, 0x30);

    public static Color For(double remainingPercent) => remainingPercent > 30
        ? Normal
        : remainingPercent > 10 ? Warning : Danger;

    public static Icon CreateRingIcon(double? remainingPercent)
    {
        const int size = 32;
        var bitmap = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.Clear(Color.Transparent);

        var remaining = Math.Clamp(remainingPercent ?? 0, 0, 100);
        var color = remainingPercent is null ? Color.Gray : For(remaining);
        var width = remaining == 0 && remainingPercent is not null ? 2f : 4f;
        var rect = new RectangleF(5, 5, 22, 22);
        using var track = new Pen(
            remaining == 0 && remainingPercent is not null ? color : Color.FromArgb(225, 231, 239),
            width);
        graphics.DrawEllipse(track, rect);
        if (remaining > 0)
        {
            using var progress = new Pen(color, 4f) { StartCap = LineCap.Flat, EndCap = LineCap.Flat };
            graphics.DrawArc(progress, rect, -90, (float)(remaining * 3.6));
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var icon = Icon.FromHandle(handle);
            return (Icon)icon.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(handle);
        }
    }

    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        public static extern bool DestroyIcon(nint handle);
    }
}
