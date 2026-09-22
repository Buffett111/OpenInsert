namespace OpenInsert.Windows;

internal sealed class ShortcutRecorderDialog : Form
{
    private readonly Label display;
    private readonly Button save;
    public uint Modifiers { get; private set; }
    public uint VirtualKey { get; private set; }

    public ShortcutRecorderDialog(bool chinese)
    {
        Text = chinese ? "錄製快捷鍵" : "Record shortcut";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MaximizeBox = MinimizeBox = false;
        ShowInTaskbar = false;
        ClientSize = new Size(490, 200);
        var help = new Label { Text = chinese ? "按下 Ctrl 或 Alt 加上一個按鍵，或單獨使用 F1–F24。\nEscape 取消；儲存時會檢查是否衝突。" : "Press Ctrl or Alt plus a key, or F1–F24 alone.\nEscape cancels; conflicts are checked when you save.", AutoSize = false, Bounds = new Rectangle(20, 16, 450, 60) };
        display = new Label { Text = chinese ? "等待按鍵…" : "Waiting for a shortcut…", AutoSize = false, Bounds = new Rectangle(20, 85, 450, 45), Font = new Font(Font.FontFamily, 16, FontStyle.Bold) };
        save = new Button { Text = chinese ? "使用此快捷鍵" : "Use shortcut", Enabled = false, Bounds = new Rectangle(290, 147, 180, 34), DialogResult = DialogResult.OK };
        Controls.AddRange([help, display, save]);
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        var key = keyData & Keys.KeyCode;
        if (key == Keys.Escape) { DialogResult = DialogResult.Cancel; Close(); return true; }
        uint modifiers = (keyData.HasFlag(Keys.Alt) ? 1u : 0u) | (keyData.HasFlag(Keys.Control) ? 2u : 0u) | (keyData.HasFlag(Keys.Shift) ? 4u : 0u);
        if (IsValid(modifiers, (uint)key))
        {
            Modifiers = modifiers;
            VirtualKey = (uint)key;
            display.Text = Format(modifiers, (uint)key);
            save.Enabled = true;
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    public static bool IsValid(uint modifiers, uint key) =>
        (modifiers & ~7u) == 0 && key >= 8 && key <= 254 &&
        key is not (16 or 17 or 18 or 27 or 91 or 92 or 93 or 160 or 161 or 162 or 163 or 164 or 165) &&
        ((modifiers & 3) != 0 || key is >= 112 and <= 135);

    public static string Format(uint modifiers, uint key) =>
        ((modifiers & 2) != 0 ? "Ctrl + " : "") + ((modifiers & 1) != 0 ? "Alt + " : "") +
        ((modifiers & 4) != 0 ? "Shift + " : "") + ((Keys)key).ToString();
}
