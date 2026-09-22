using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Interop;

/// <summary>A disposable editor that intentionally exposes ValuePattern without TextPattern.</summary>
internal static class ValueOnlyTarget
{
    internal static void Run(string title)
    {
        var editor = new ValueOnlyTextBox { Text = "seed" };
        AutomationProperties.SetAutomationId(editor, "ValueOnlyEditor");
        var other = new ValueOnlyTextBox { Text = "other" };
        var password = new PasswordBox();
        var panel = new StackPanel();
        panel.Children.Add(editor);
        panel.Children.Add(other);
        panel.Children.Add(password);
        var window = new Window { Title = title, Width = 500, Height = 180, Content = panel };
        window.SourceInitialized += (_, _) =>
        {
            var source = HwndSource.FromHwnd(new WindowInteropHelper(window).Handle);
            source.AddHook((nint _, int message, nint wParam, nint lParam, ref bool handled) =>
            {
                switch (message)
                {
                    case 0x8101: other.Focus(); handled = true; break;
                    case 0x8102: editor.IsReadOnly = true; editor.Focus(); handled = true; break;
                    case 0x8103: password.Focus(); handled = true; break;
                }
                return 0;
            });
        };
        window.ContentRendered += (_, _) => { window.Activate(); editor.Focus(); editor.Select(editor.Text.Length, 0); };
        new Application().Run(window);
    }

    private sealed class ValueOnlyTextBox : TextBox
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new ValueOnlyPeer(this);
    }

    private sealed class ValueOnlyPeer(TextBox owner) : TextBoxAutomationPeer(owner)
    {
        public override object? GetPattern(PatternInterface patternInterface) =>
            patternInterface == PatternInterface.Text ? null : base.GetPattern(patternInterface);
    }
}
