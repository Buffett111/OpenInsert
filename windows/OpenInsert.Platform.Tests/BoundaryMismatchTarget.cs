using System;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Automation.Text;
using System.Windows.Controls;
using System.Windows.Interop;

/// <summary>Models a writable Chromium editor whose document and selection boundaries differ.</summary>
internal static class BoundaryMismatchTarget
{
    internal static void Run(string title)
    {
        var editor = new BoundaryTextBox();
        AutomationProperties.SetAutomationId(editor, "BoundaryEditor");
        var window = new Window { Title = title, Width = 500, Height = 180, Content = editor };
        window.SourceInitialized += (_, _) =>
        {
            var source = HwndSource.FromHwnd(new WindowInteropHelper(window).Handle);
            source.AddHook((nint _, int message, nint wParam, nint lParam, ref bool handled) =>
            {
                if (message == 0x8101) { editor.Select(0, 0); handled = true; }
                return 0;
            });
        };
        window.ContentRendered += (_, _) => { window.Activate(); editor.Focus(); };
        new Application().Run(window);
    }

    private sealed class BoundaryTextBox : TextBox
    {
        protected override AutomationPeer OnCreateAutomationPeer() => new BoundaryPeer(this);
    }

    private sealed class BoundaryPeer(TextBox owner) : TextBoxAutomationPeer(owner)
    {
        private ITextProvider? text;
        public override object? GetPattern(PatternInterface patternInterface) => patternInterface == PatternInterface.Text
            ? text ??= new BoundaryTextProvider((ITextProvider)base.GetPattern(patternInterface))
            : base.GetPattern(patternInterface);
    }

    private sealed class BoundaryTextProvider(ITextProvider inner) : ITextProvider
    {
        public ITextRangeProvider DocumentRange => new BoundaryRange(inner.DocumentRange, true);
        public SupportedTextSelection SupportedTextSelection => inner.SupportedTextSelection;
        public ITextRangeProvider[] GetSelection() => inner.GetSelection().Select(range => (ITextRangeProvider)new BoundaryRange(range, false)).ToArray();
        public ITextRangeProvider[] GetVisibleRanges() => inner.GetVisibleRanges().Select(range => (ITextRangeProvider)new BoundaryRange(range, false)).ToArray();
        public ITextRangeProvider RangeFromChild(IRawElementProviderSimple childElement) => new BoundaryRange(inner.RangeFromChild(childElement), false);
        public ITextRangeProvider RangeFromPoint(Point screenLocation) => new BoundaryRange(inner.RangeFromPoint(screenLocation), false);
    }

    private sealed class BoundaryRange(ITextRangeProvider inner, bool document) : ITextRangeProvider
    {
        private readonly ITextRangeProvider inner = inner;
        private readonly bool document = document;
        private static ITextRangeProvider Unwrap(ITextRangeProvider range) => ((BoundaryRange)range).inner;
        public ITextRangeProvider Clone() => new BoundaryRange(inner.Clone(), document);
        public bool Compare(ITextRangeProvider range) => inner.Compare(Unwrap(range));
        public int CompareEndpoints(TextPatternRangeEndpoint endpoint, ITextRangeProvider targetRange, TextPatternRangeEndpoint targetEndpoint)
        {
            // Old offset code moved the selection to its start, then incorrectly
            // assumed it must equal DocumentRange.Start. Reproduce that mismatch.
            if (targetRange is BoundaryRange target && target.document != document) return document ? -1 : 1;
            return inner.CompareEndpoints(endpoint, Unwrap(targetRange), targetEndpoint);
        }
        public void ExpandToEnclosingUnit(TextUnit unit) => inner.ExpandToEnclosingUnit(unit);
        public ITextRangeProvider? FindAttribute(int attributeId, object value, bool backward)
        { var result = inner.FindAttribute(attributeId, value, backward); return result is null ? null : new BoundaryRange(result, document); }
        public ITextRangeProvider? FindText(string text, bool backward, bool ignoreCase)
        { var result = inner.FindText(text, backward, ignoreCase); return result is null ? null : new BoundaryRange(result, document); }
        public object GetAttributeValue(int attributeId) => inner.GetAttributeValue(attributeId);
        public double[] GetBoundingRectangles() => inner.GetBoundingRectangles();
        public IRawElementProviderSimple GetEnclosingElement() => inner.GetEnclosingElement();
        public string GetText(int maxLength) => inner.GetText(maxLength);
        public int Move(TextUnit unit, int count) => inner.Move(unit, count);
        public int MoveEndpointByUnit(TextPatternRangeEndpoint endpoint, TextUnit unit, int count) => inner.MoveEndpointByUnit(endpoint, unit, count);
        public void MoveEndpointByRange(TextPatternRangeEndpoint endpoint, ITextRangeProvider targetRange, TextPatternRangeEndpoint targetEndpoint) =>
            inner.MoveEndpointByRange(endpoint, Unwrap(targetRange), targetEndpoint);
        public void Select() => inner.Select();
        public void AddToSelection() => inner.AddToSelection();
        public void RemoveFromSelection() => inner.RemoveFromSelection();
        public void ScrollIntoView(bool alignToTop) => inner.ScrollIntoView(alignToTop);
        public IRawElementProviderSimple[] GetChildren() => inner.GetChildren();
    }
}
