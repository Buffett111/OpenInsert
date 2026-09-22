using System.Runtime.InteropServices;
using System.Text;

namespace OpenInsert.Windows.Platform;

/// <summary>Atomic clipboard ownership checks and eager native-format backups. No deserialization or files.</summary>
internal sealed class NativeClipboard : System.Windows.Forms.NativeWindow, IDisposable
{
    private const int MaximumBytes = 128 * 1024 * 1024;
    private bool disposed;
    public NativeClipboard() => CreateHandle(new System.Windows.Forms.CreateParams
        { Caption = "OpenInsert clipboard", Parent = new nint(-3) });

    internal sealed class ClipboardFailure(string message) : IOException(message);

    internal sealed class Snapshot : IDisposable
    {
        internal readonly List<Item> Items = [];
        internal uint Sequence;
        public void Dispose() { foreach (var item in Items) item.Dispose(); Items.Clear(); }
    }

    internal Snapshot Capture()
    {
        Open();
        var snapshot = new Snapshot();
        try
        {
            long totalBytes = 0;
            uint format = 0;
            var seen = new HashSet<uint>();
            while (true)
            {
                Marshal.SetLastPInvokeError(0);
                format = EnumClipboardFormats(format);
                if (format == 0)
                {
                    if (Marshal.GetLastWin32Error() != 0) throw Unreadable();
                    break;
                }
                if (!seen.Add(format) || seen.Count > 1024) throw Unreadable();
                // Private object formats have application-defined lifetimes or handle semantics.
                // A lossless independent backup cannot be proved, so leave the clipboard intact.
                if (format is 0x80 or >= 0x200 and <= 0x3FF) throw Unreadable();
                var original = GetClipboardData(format);
                if (original == 0) throw Unreadable();
                var copy = Duplicate(format, original, ref totalBytes);
                snapshot.Items.Add(copy);
            }
            snapshot.Sequence = Sequence();
            return snapshot;
        }
        catch { snapshot.Dispose(); throw; }
        finally { CloseClipboard(); }
    }

    internal uint WriteText(string text, Snapshot previous)
    {
        // Prepare the Unicode allocation before taking or clearing the clipboard.
        using var item = Item.Memory(13, Encoding.Unicode.GetBytes(text + '\0'));
        var textHandle = item.Handle;
        Open();
        try
        {
            if (Sequence() != previous.Sequence) throw Changed();
            if (!EmptyClipboard()) throw WriteFailed();
            if (SetClipboardData(13, item.Handle) == 0)
            {
                RestoreContents(previous);
                throw WriteFailed();
            }
            item.TransferOwnership();
        }
        finally { CloseClipboard(); }
        // Closing a Unicode clipboard write synthesizes ANSI/OEM formats and increments the
        // sequence again. Reopen atomically and prove that our exact Unicode allocation and
        // owner survived; never adopt another application's newer sequence as our own.
        Open();
        try
        {
            if (GetClipboardOwner() != Handle || GetClipboardData(13) != textHandle) throw Changed();
            return Sequence();
        }
        finally { CloseClipboard(); }
    }

    internal bool IsOwned(uint sequence) => GetClipboardSequenceNumber() == sequence && GetClipboardOwner() == Handle;

    internal bool RestoreIfOwned(Snapshot previous, uint sequence)
    {
        // Failure to acquire the clipboard also means we cannot establish ownership safely.
        // Never wait and then overwrite a copy made while waiting.
        if (!OpenClipboard(Handle)) return false;
        try
        {
            if (!IsOwned(sequence)) return false;
            RestoreContents(previous);
            return true;
        }
        finally { CloseClipboard(); }
    }

    private static void RestoreContents(Snapshot previous)
    {
        if (!EmptyClipboard()) throw WriteFailed();
        foreach (var item in previous.Items)
        {
            if (item.Handle == 0 || SetClipboardData(item.Format, item.Handle) == 0)
                throw new ClipboardFailure("Windows could not fully restore the clipboard. The result remains visible in OpenInsert; delivery was not retried.");
            item.TransferOwnership();
        }
    }

    private void Open()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!OpenClipboard(Handle))
            throw new ClipboardFailure("The clipboard is busy. It was left unchanged; copy the result manually.");
    }
    private static uint Sequence()
    {
        var sequence = GetClipboardSequenceNumber();
        if (sequence == 0) throw new ClipboardFailure("Clipboard ownership could not be verified. Copy the result manually.");
        return sequence;
    }
    private static ClipboardFailure Unreadable() => new("All clipboard formats could not be backed up safely. The clipboard was left unchanged; copy the result manually.");
    private static ClipboardFailure Changed() => new("The clipboard changed before paste. Newer clipboard contents were preserved; copy the result manually.");
    private static ClipboardFailure WriteFailed() => new("Windows could not write the clipboard. Delivery was not retried; copy the result manually.");

    private static Item Duplicate(uint format, nint original, ref long totalBytes)
    {
        if (format is 2 or 0x82) // CF_BITMAP / CF_DSPBITMAP
        {
            var duplicate = CopyImage(original, 0, 0, 0, 0x2000); // LR_CREATEDIBSECTION, no shared handle.
            if (duplicate == 0 || duplicate == original) throw Unreadable();
            return new Item(format, duplicate, ObjectKind.Gdi);
        }
        if (format is 14 or 0x8E)
        {
            var duplicate = CopyEnhMetaFile(original, null);
            if (duplicate == 0) throw Unreadable();
            return new Item(format, duplicate, ObjectKind.EnhancedMetafile);
        }
        if (format is 3 or 0x83)
        {
            var source = GlobalLock(original);
            if (source == 0) throw Unreadable();
            MetaFilePicture picture;
            try
            {
                if (GlobalSize(original) < (nuint)Marshal.SizeOf<MetaFilePicture>()) throw Unreadable();
                picture = Marshal.PtrToStructure<MetaFilePicture>(source);
            }
            finally { GlobalUnlock(original); }
            picture.Metafile = CopyMetaFile(picture.Metafile, null);
            if (picture.Metafile == 0) throw Unreadable();
            var memory = GlobalAlloc(2, (nuint)Marshal.SizeOf<MetaFilePicture>());
            if (memory == 0) { DeleteMetaFile(picture.Metafile); throw Unreadable(); }
            var destination = GlobalLock(memory);
            if (destination == 0) { GlobalFree(memory); DeleteMetaFile(picture.Metafile); throw Unreadable(); }
            try { Marshal.StructureToPtr(picture, destination, false); }
            finally { GlobalUnlock(memory); }
            return new Item(format, memory, ObjectKind.MetafilePicture);
        }
        if (format == 9)
        {
            var count = GetPaletteEntries(original, 0, 0, null);
            if (count is 0 or > 65535) throw Unreadable();
            var entries = new byte[count * 4];
            if (GetPaletteEntries(original, 0, count, entries) != count) throw Unreadable();
            var palette = new byte[4 + entries.Length];
            palette[0] = 0; palette[1] = 3;
            palette[2] = (byte)count; palette[3] = (byte)(count >> 8);
            entries.CopyTo(palette, 4);
            var duplicate = CreatePalette(palette);
            if (duplicate == 0) throw Unreadable();
            return new Item(format, duplicate, ObjectKind.Gdi);
        }
        var size = GlobalSize(original);
        if (size == 0 || size > MaximumBytes || (totalBytes += (long)size) > MaximumBytes) throw Unreadable();
        var pointer = GlobalLock(original);
        if (pointer == 0) throw Unreadable();
        byte[] bytes;
        try
        {
            bytes = new byte[(int)size];
            Marshal.Copy(pointer, bytes, 0, bytes.Length);
        }
        finally { GlobalUnlock(original); }
        return Item.Memory(format, bytes);
    }

    internal enum ObjectKind { Memory, Gdi, EnhancedMetafile, MetafilePicture }
    internal sealed class Item(uint format, nint handle, ObjectKind kind) : IDisposable
    {
        internal uint Format { get; } = format;
        internal nint Handle { get; private set; } = handle;
        internal void TransferOwnership() => Handle = 0;
        internal static Item Memory(uint format, byte[] bytes)
        {
            var memory = GlobalAlloc(2, (nuint)bytes.Length);
            if (memory == 0) throw Unreadable();
            var pointer = GlobalLock(memory);
            if (pointer == 0) { GlobalFree(memory); throw Unreadable(); }
            try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
            finally { GlobalUnlock(memory); }
            return new Item(format, memory, ObjectKind.Memory);
        }
        public void Dispose()
        {
            if (Handle == 0) return;
            switch (kind)
            {
                case ObjectKind.Gdi: DeleteObject(Handle); break;
                case ObjectKind.EnhancedMetafile: DeleteEnhMetaFile(Handle); break;
                case ObjectKind.MetafilePicture:
                    var pointer = GlobalLock(Handle);
                    if (pointer != 0)
                    {
                        var picture = Marshal.PtrToStructure<MetaFilePicture>(pointer);
                        GlobalUnlock(Handle);
                        DeleteMetaFile(picture.Metafile);
                    }
                    GlobalFree(Handle);
                    break;
                default: GlobalFree(Handle); break;
            }
            Handle = 0;
        }
    }

    public void Dispose() { if (disposed) return; disposed = true; DestroyHandle(); }
    [StructLayout(LayoutKind.Sequential)] private struct MetaFilePicture { public int MappingMode, Width, Height; public nint Metafile; }
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint GetClipboardData(uint format);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint SetClipboardData(uint format, nint data);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern nint GetClipboardOwner();
    [DllImport("kernel32.dll")] private static extern nint GlobalAlloc(uint flags, nuint bytes);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GlobalUnlock(nint memory);
    [DllImport("kernel32.dll")] private static extern nuint GlobalSize(nint memory);
    [DllImport("kernel32.dll")] private static extern nint GlobalFree(nint memory);
    [DllImport("user32.dll")] private static extern nint CopyImage(nint source, uint type, int width, int height, uint flags);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern nint CopyEnhMetaFile(nint metafile, string? fileName);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] private static extern nint CopyMetaFile(nint metafile, string? fileName);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteObject(nint value);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteEnhMetaFile(nint metafile);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DeleteMetaFile(nint metafile);
    [DllImport("gdi32.dll")] private static extern uint GetPaletteEntries(nint palette, uint start, uint count, [Out] byte[]? entries);
    [DllImport("gdi32.dll")] private static extern nint CreatePalette(byte[] palette);
}
