using System.Runtime.InteropServices;

namespace OpenInsert.Windows;

/// <summary>Click-through, non-activating captions. It never captures the screen.</summary>
internal sealed class DictationOverlay : Form
{
    private string caption = "";
    private string status = "";
    private readonly Queue<float> levels = new();
    private readonly System.Windows.Forms.Timer hideTimer = new();
    private bool recording;
    private bool error;
    public DictationOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.FromArgb(23, 32, 30);
        ForeColor = Color.White;
        DoubleBuffered = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(440, 145);
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); Hide(); };
        AccessibleName = "OpenInsert dictation status";
    }
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000020; // NOACTIVATE, TOOLWINDOW, TRANSPARENT
            return cp;
        }
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x84) { m.Result = (IntPtr)(-1); return; } // HTTRANSPARENT
        if (m.Msg == 0x21) { m.Result = (IntPtr)3; return; } // MA_NOACTIVATE
        base.WndProc(ref m);
    }
    public void Present(string message, string preview, bool isRecording, bool isError = false, int dismissAfterMs = 0)
    {
        hideTimer.Stop();
        status = message;
        caption = preview;
        recording = isRecording;
        error = isError;
        if (!isRecording) levels.Clear();
        if (!Visible)
        {
            var foreground = GetForegroundWindow();
            var area = (foreground != IntPtr.Zero ? Screen.FromHandle(foreground) : Screen.PrimaryScreen!).WorkingArea;
            Width = Math.Min((int)(440 * DeviceDpi / 96f), Math.Max(240, area.Width - 32));
            Location = new Point(area.Left + (area.Width - Width) / 2, area.Bottom - Height - 28);
            Show();
        }
        Invalidate();
        if (dismissAfterMs > 0) { hideTimer.Interval = dismissAfterMs; hideTimer.Start(); }
    }
    public void Dismiss() { hideTimer.Stop(); Hide(); }
    public void AddLevel(float level)
    {
        levels.Enqueue(Math.Clamp(level, 0f, 1f));
        while (levels.Count > 90) levels.Dequeue();
        Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var scale = DeviceDpi / 96f;
        int pad = (int)(16 * scale), top = pad;
        using var brush = new SolidBrush(error ? Color.FromArgb(255, 182, 162) : Color.FromArgb(82, 218, 162));
        if (recording)
        {
            int x = pad;
            foreach (var level in levels)
            {
                var amplitude = (int)(3 * scale + Math.Sqrt(level) * 23 * scale);
                e.Graphics.FillRectangle(brush, x, top + (int)(14 * scale) - amplitude / 2, Math.Max(2, 2 * scale), amplitude);
                x += (int)(4 * scale);
            }
            top += (int)(36 * scale);
        }
        TextRenderer.DrawText(e.Graphics, status, Font, new Rectangle(pad, top, Width - pad * 2, (int)(40 * scale)), ((SolidBrush)brush).Color,
            TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        if (!string.IsNullOrEmpty(caption))
        {
            using var previewFont = new Font(Font.FontFamily, 11);
            TextRenderer.DrawText(e.Graphics, caption, previewFont, new Rectangle(pad, top + (int)(43 * scale), Width - pad * 2, Height - top - (int)(48 * scale)), ForeColor,
                TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) hideTimer.Dispose();
        base.Dispose(disposing);
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
}
