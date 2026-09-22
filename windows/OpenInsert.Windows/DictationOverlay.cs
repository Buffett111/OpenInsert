using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

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
    private DictationOverlayFrame? frame;

    public DictationOverlay()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        BackColor = DictationOverlayFrame.Background;
        ForeColor = Color.White;
        DoubleBuffered = true;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(440, 60);
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
        var foreground = GetForegroundWindow();
        var screen = Visible ? Screen.FromControl(this)
            : foreground != IntPtr.Zero ? Screen.FromHandle(foreground) : Screen.PrimaryScreen!;
        UpdateFrame(screen.WorkingArea);
        if (!Visible) Show();
        Invalidate();
        if (dismissAfterMs > 0) { hideTimer.Interval = dismissAfterMs; hideTimer.Start(); }
    }

    private void UpdateFrame(Rectangle area)
    {
        using var graphics = CreateGraphics();
        var margin = (int)Math.Round(16 * DeviceDpi / 96f);
        var width = Math.Min((int)Math.Round(440 * DeviceDpi / 96f), Math.Max(1, area.Width - margin * 2));
        frame = DictationOverlayFrame.Create(graphics, DeviceDpi, width, status, caption, recording, error);
        ClientSize = frame.Size;
        Location = new Point(area.Left + (area.Width - Width) / 2,
            Math.Max(area.Top, area.Bottom - Height - (int)Math.Round(28 * DeviceDpi / 96f)));
        AccessibleDescription = recording && !error ? caption : status + " " + caption;
    }

    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        // WinForms applies its suggested scaled bounds after this event. Measure
        // after that resize so our content-derived height is not scaled twice.
        if (frame != null) BeginInvoke(() =>
        {
            if (IsDisposed || Disposing) return;
            UpdateFrame(Screen.FromControl(this).WorkingArea);
            Invalidate();
        });
    }

    public void Dismiss() { hideTimer.Stop(); Hide(); }
    public void AddLevel(float level)
    {
        levels.Enqueue(float.IsFinite(level) ? Math.Clamp(level, 0f, 1f) : 0f);
        while (levels.Count > 96) levels.Dequeue();
        Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        frame?.Draw(e.Graphics, levels);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) hideTimer.Dispose();
        base.Dispose(disposing);
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
}

/// <summary>Measures and draws the same frame on screen and in app-only render checks.</summary>
internal sealed record DictationOverlayFrame(
    int Dpi, Size Size, Rectangle WaveformBounds, Rectangle StatusBounds, Rectangle CaptionBounds,
    string Status, string Caption, bool Error)
{
    internal static readonly Color Background = Color.FromArgb(23, 32, 30);
    internal const TextFormatFlags CaptionFlags = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix
        | TextFormatFlags.NoPadding | TextFormatFlags.TextBoxControl;

    internal static Font CreateCaptionFont(int dpi) => new("Segoe UI", 15 * dpi / 96f, FontStyle.Regular, GraphicsUnit.Pixel);
    private static Font CreateStatusFont(int dpi) => new("Segoe UI", 13 * dpi / 96f, FontStyle.Regular, GraphicsUnit.Pixel);

    internal static DictationOverlayFrame Create(IDeviceContext context, int dpi, int width,
        string status, string caption, bool recording, bool error)
    {
        int Scale(int value) => Math.Max(1, (int)Math.Round(value * dpi / 96f));
        int padding = Scale(16), gap = Scale(8), contentWidth = Math.Max(1, width - padding * 2), top = padding;
        Rectangle waveform = Rectangle.Empty, statusBounds = Rectangle.Empty, captionBounds = Rectangle.Empty;
        if (recording)
        {
            waveform = new Rectangle(padding, top, contentWidth, Scale(28));
            top = waveform.Bottom;
        }

        // During recording, reserve the display for sound and incoming words.
        // Finishing and error messages remain available.
        var visibleStatus = !recording || error ? status : "";
        if (!string.IsNullOrWhiteSpace(visibleStatus))
        {
            if (top > padding) top += gap;
            using var font = CreateStatusFont(dpi);
            var height = Math.Min(font.Height * 4, TextRenderer.MeasureText(context, visibleStatus, font,
                new Size(contentWidth, int.MaxValue), CaptionFlags).Height);
            statusBounds = new Rectangle(padding, top, contentWidth, height);
            top = statusBounds.Bottom;
        }

        using var captionFont = CreateCaptionFont(dpi);
        var maxCaptionHeight = captionFont.Height * 4;
        Size Measure(string text) => TextRenderer.MeasureText(context, text, captionFont,
            new Size(contentWidth, int.MaxValue), CaptionFlags);
        var visibleCaption = DictationCaption.Latest(caption, text =>
        {
            var size = Measure(text);
            return size.Height <= maxCaptionHeight && size.Width <= contentWidth;
        });
        if (visibleCaption.Length > 0)
        {
            if (top > padding) top += gap;
            captionBounds = new Rectangle(padding, top, contentWidth, Measure(visibleCaption).Height);
            top = captionBounds.Bottom;
        }

        return new DictationOverlayFrame(dpi, new Size(width, top + padding), waveform, statusBounds,
            captionBounds, visibleStatus, visibleCaption, error);
    }

    internal void Draw(Graphics graphics, IEnumerable<float> levels)
    {
        graphics.Clear(Background);
        var scale = Dpi / 96f;
        using var accent = new SolidBrush(Error ? Color.FromArgb(255, 182, 162) : Color.FromArgb(82, 218, 162));
        if (!WaveformBounds.IsEmpty)
        {
            int spacing = Math.Max(1, (int)Math.Round(4 * scale));
            int count = Math.Max(1, Math.Min(96, WaveformBounds.Width / spacing));
            var recent = levels.TakeLast(count).ToArray();
            // A quiet baseline also conveys recording before the first microphone sample.
            for (int i = 0; i < count; i++)
            {
                var index = i - (count - recent.Length);
                var level = index < 0 ? 0 : recent[index];
                var amplitude = (float)(2 * scale + Math.Sqrt(level) * 26 * scale);
                graphics.FillRectangle(accent, WaveformBounds.Left + i * spacing,
                    WaveformBounds.Top + (WaveformBounds.Height - amplitude) / 2,
                    Math.Max(1, 2 * scale), amplitude);
            }
        }
        if (!StatusBounds.IsEmpty)
        {
            using var font = CreateStatusFont(Dpi);
            TextRenderer.DrawText(graphics, Status, font, StatusBounds, accent.Color,
                CaptionFlags | TextFormatFlags.EndEllipsis);
        }
        if (!CaptionBounds.IsEmpty)
        {
            using var font = CreateCaptionFont(Dpi);
            TextRenderer.DrawText(graphics, Caption, font, CaptionBounds, Color.White, CaptionFlags);
        }
    }
}

internal static class DictationCaption
{
    /// <summary>Keep the newest words visible without splitting emoji or combining characters.</summary>
    internal static string Latest(string text, Func<string, bool> fits)
    {
        var normalized = new StringBuilder(text.Length);
        bool space = false;
        foreach (var character in text)
        {
            if (char.IsWhiteSpace(character)) { space = normalized.Length > 0; continue; }
            if (space) normalized.Append(' ');
            normalized.Append(character);
            space = false;
        }
        text = normalized.ToString();
        if (text.Length == 0) return "";
        var starts = StringInfo.ParseCombiningCharacters(text);
        if (starts.Length <= 420 && fits(text)) return text;

        // Match macOS's bounded live preview, then remove older text until all
        // remaining lines fit. Never use end ellipsis: the changing tail matters.
        int low = Math.Max(1, starts.Length - 420), high = starts.Length;
        string Suffix(int start) => start < starts.Length ? "… " + text[starts[start]..] : "";
        while (low < high)
        {
            int middle = low + (high - low) / 2;
            if (fits(Suffix(middle))) high = middle;
            else low = middle + 1;
        }
        return Suffix(low);
    }
}
