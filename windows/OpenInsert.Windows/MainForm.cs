using System.Diagnostics;
using OpenInsert.Core;
using OpenInsert.Windows.Platform;

namespace OpenInsert.Windows;

internal sealed class MainForm : Form
{
    private AppSettings settings;
    private readonly bool smokeTest;
    private DictationController? controller;
    private GlobalShortcut? shortcut;
    private readonly DictationOverlay overlay = new();
    private NotifyIcon? tray;
    private bool exiting;
    private bool keyExists;
    private TextBox keyBox = null!, vocabularyBox = null!, liveModelBox = null!, cleanupModelBox = null!, customLanguageBox = null!, resultBox = null!;
    private CheckBox consentBox = null!, polishBox = null!, restoreBox = null!;
    private ComboBox interfaceBox = null!, languageBox = null!;
    private Label statusLabel = null!, keyLabel = null!, shortcutLabel = null!;
    private Button stopButton = null!, cancelButton = null!, skipButton = null!, saveButton = null!, copyButton = null!;
    private TabControl tabs = null!;
    private uint pendingModifiers, pendingKey;
    private readonly List<Control> idleControls = new();
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public string InitialNotice { get; set; } = "";
    public bool HasRequiredControls => tabs.TabPages.Count == 3 && resultBox.ReadOnly && keyBox.UseSystemPasswordChar;
    protected override bool ShowWithoutActivation => smokeTest;
    private bool Chinese => settings.InterfaceLanguage != "en";
    private string T(string zh, string en) => Chinese ? zh : en;

    public MainForm(AppSettings settings, bool smokeTest = false)
    {
        this.settings = settings;
        this.smokeTest = smokeTest;
        Text = "OpenInsert";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(650, 680);
        ClientSize = new Size(760, 770);
        BackColor = Color.FromArgb(247, 249, 247);
        Icon = SystemIcons.Application;
        BuildInterface();
        Shown += (_, _) => InitializeServices();
        FormClosing += OnClosing;
    }

    private void BuildInterface()
    {
        SuspendLayout();
        while (Controls.Count > 0) Controls[0].Dispose();
        idleControls.Clear();
        pendingModifiers = settings.ShortcutModifiers;
        pendingKey = settings.ShortcutKey;
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(24) };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 92));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 66));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        var heading = new Panel { Dock = DockStyle.Fill };
        heading.Controls.Add(new Label { Text = "OpenInsert", Font = new Font(Font.FontFamily, 24, FontStyle.Bold), ForeColor = Color.FromArgb(18, 83, 63), AutoSize = true, Location = new Point(0, 0) });
        heading.Controls.Add(new Label { Text = T("按住快捷鍵，說話，放開。文字回到游標所在位置。", "Hold your shortcut, speak, release. Words go where your cursor is."), AutoSize = true, Location = new Point(2, 53) });
        root.Controls.Add(heading, 0, 0);
        tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(16, 8) };
        var connection = CreatePage(T("連線", "Connection"));
        var preferences = CreatePage(T("辨識偏好", "Preferences"));
        var results = CreatePage(T("結果與測試", "Results & tests"));
        BuildConnection(connection);
        BuildPreferences(preferences);
        BuildResults(results);
        root.Controls.Add(tabs, 0, 1);
        statusLabel = new Label { AutoSize = false, Dock = DockStyle.Fill, Padding = new Padding(3, 12, 3, 0), Text = T("準備就緒。請先完成連線設定，再使用快捷鍵。", "Ready. Configure your connection, then use the shortcut."), ForeColor = Color.FromArgb(57, 76, 66) };
        root.Controls.Add(statusLabel, 0, 2);
        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        saveButton = MakeButton(T("儲存設定", "Save settings"), SaveSettings);
        saveButton.BackColor = Color.FromArgb(22, 105, 77);
        saveButton.ForeColor = Color.White;
        saveButton.FlatStyle = FlatStyle.Flat;
        stopButton = MakeButton(T("完成錄音", "Finish recording"), () => controller?.Stop());
        cancelButton = MakeButton(T("取消", "Cancel"), () => controller?.Cancel());
        skipButton = MakeButton(T("略過整理", "Skip cleanup"), () => controller?.SkipCleanup());
        stopButton.Enabled = cancelButton.Enabled = skipButton.Enabled = false;
        footer.Controls.AddRange([saveButton, stopButton, cancelButton, skipButton]);
        root.Controls.Add(footer, 0, 3);
        Controls.Add(root);
        ResumeLayout(true);
        if (controller != null) RefreshState();
    }

    private TableLayoutPanel CreatePage(string title)
    {
        var page = new TabPage(title) { BackColor = Color.White, AutoScroll = true, Padding = new Padding(18) };
        var table = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, GrowStyle = TableLayoutPanelGrowStyle.AddRows, Margin = Padding.Empty };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        page.Controls.Add(table);
        tabs.TabPages.Add(page);
        return table;
    }
    private static void AddRow(TableLayoutPanel panel, Control control, int height = 0)
    {
        int row = panel.RowCount++;
        panel.RowStyles.Add(height > 0 ? new RowStyle(SizeType.Absolute, height) : new RowStyle(SizeType.AutoSize));
        control.Dock = DockStyle.Fill;
        control.Margin = new Padding(0, 3, 0, 9);
        panel.Controls.Add(control, 0, row);
    }
    private static Label TextLabel(string text, bool bold = false) => new()
    {
        Text = text, AutoSize = true, MaximumSize = new Size(610, 0),
        Font = new Font("Segoe UI", 10, bold ? FontStyle.Bold : FontStyle.Regular)
    };
    private static TextBox Input(string text = "") => new() { Text = text, BorderStyle = BorderStyle.FixedSingle };
    private static Button MakeButton(string text, Action action)
    {
        var b = new Button { Text = text, AutoSize = true, MinimumSize = new Size(92, 34), Padding = new Padding(7, 0, 7, 0), Margin = new Padding(0, 0, 8, 0) };
        b.Click += (_, _) => action();
        return b;
    }
    private static FlowLayoutPanel Buttons(params Control[] controls)
    {
        var panel = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
        panel.Controls.AddRange(controls);
        return panel;
    }

    private void BuildConnection(TableLayoutPanel panel)
    {
        AddRow(panel, TextLabel(T("你的 Gemini API 金鑰", "Your Gemini API key"), true));
        AddRow(panel, TextLabel(T("金鑰以目前 Windows 帳號加密儲存，不包含在下載檔案中。", "The key is encrypted for your Windows account and is never included in downloads.")));
        keyBox = Input();
        keyBox.UseSystemPasswordChar = true;
        keyBox.PlaceholderText = T("貼上完整金鑰（保留句點等符號）", "Paste the complete key, including punctuation");
        keyBox.MaxLength = 8192;
        AddRow(panel, keyBox, 42);
        keyLabel = TextLabel(KeyStatus());
        AddRow(panel, keyLabel);
        var saveKey = MakeButton(T("儲存金鑰", "Save key"), SaveKey);
        var removeKey = MakeButton(T("刪除金鑰", "Delete key"), DeleteKey);
        var getKey = MakeButton(T("取得 Gemini 金鑰", "Get a Gemini key"), () => OpenLink("https://aistudio.google.com/apikey"));
        AddRow(panel, Buttons(saveKey, removeKey, getKey));
        AddRow(panel, TextLabel(T("雲端處理同意", "Cloud processing consent"), true));
        AddRow(panel, TextLabel(T("錄音時，音訊與自訂詞彙會直接傳送給 Google。啟用文字整理時，也會傳送辨識文字與語言偏好。可能產生 API 費用；取消無法收回已傳送資料。", "Audio and vocabulary are sent directly to Google during recording. Optional cleanup also sends the transcript and writing preferences. API charges may apply; cancellation cannot retract data already sent.")));
        consentBox = new CheckBox { Text = T("我同意上述傳送方式（勾選後請儲存設定）", "I consent to this processing (save settings to apply)"), Checked = settings.CloudConsent, AutoSize = true };
        AddRow(panel, consentBox);
        AddRow(panel, TextLabel(T("麥克風", "Microphone"), true));
        AddRow(panel, TextLabel(T("使用 Windows 預設輸入裝置。請在隱私權設定允許桌面應用程式存取麥克風，並在音效設定選擇正確裝置。", "Uses the default Windows input device. Allow desktop apps to access the microphone in Privacy settings and select the correct input in Sound settings.")));
        AddRow(panel, Buttons(MakeButton(T("麥克風隱私權", "Microphone privacy"), () => OpenLink("ms-settings:privacy-microphone")), MakeButton(T("音效設定", "Sound settings"), () => OpenLink("ms-settings:sound"))));
        AddRow(panel, TextLabel(T("不擷取畫面，不建立錄音檔案，也不保存逐字稿歷史。關閉視窗後仍在系統匣運作。", "No screen capture, audio files or transcript history. Closing this window keeps OpenInsert running in the system tray.")));
        idleControls.AddRange([keyBox, saveKey, removeKey, consentBox]);
    }

    private void BuildPreferences(TableLayoutPanel panel)
    {
        AddRow(panel, TextLabel(T("介面語言", "Interface language"), true));
        interfaceBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
        interfaceBox.Items.AddRange(["繁體中文", "English"]);
        interfaceBox.SelectedIndex = Chinese ? 0 : 1;
        AddRow(panel, interfaceBox, 42);
        AddRow(panel, TextLabel(T("全域快捷鍵", "Global shortcut"), true));
        shortcutLabel = TextLabel(settings.ShortcutName);
        AddRow(panel, shortcutLabel);
        var record = MakeButton(T("錄製快捷鍵…", "Record shortcut…"), RecordShortcut);
        AddRow(panel, Buttons(record, MakeButton(T("還原預設", "Use default"), () => { pendingModifiers = 2; pendingKey = 32; shortcutLabel.Text = ShortcutRecorderDialog.Format(pendingModifiers, pendingKey); })));
        AddRow(panel, TextLabel(T("按住至少 0.35 秒再放開即可完成；也可短按開始、再按一次結束。每次最長約兩分鐘。", "Hold for at least 0.35 seconds and release to finish, or tap once to start and again to stop. Each recording is limited to about two minutes.")));
        AddRow(panel, TextLabel(T("文字語言偏好（保留多語混用，不翻譯）", "Writing preference (preserve languages, no translation)"), true));
        languageBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
        languageBox.Items.AddRange(AppSettings.LanguageNames);
        languageBox.SelectedIndex = Array.IndexOf(AppSettings.LanguageIds, settings.WritingLanguage);
        AddRow(panel, languageBox, 42);
        customLanguageBox = Input(settings.CustomLanguage);
        customLanguageBox.PlaceholderText = T("自訂文字語言偏好", "Custom writing preference");
        customLanguageBox.Enabled = settings.WritingLanguage == "custom";
        languageBox.SelectedIndexChanged += (_, _) => customLanguageBox.Enabled = languageBox.SelectedIndex == 6;
        AddRow(panel, customLanguageBox, 42);
        polishBox = new CheckBox { Text = T("輕度整理文字（額外的 Google 文字請求，可略過）", "Light text cleanup (additional Google request; skippable)"), Checked = settings.Polish, AutoSize = true };
        restoreBox = new CheckBox { Text = T("貼上後還原剪貼簿（僅限剪貼簿未被其他程式更改時）", "Restore clipboard after paste, only if it has not changed"), Checked = settings.RestoreClipboard, AutoSize = true };
        AddRow(panel, polishBox);
        AddRow(panel, restoreBox);
        AddRow(panel, TextLabel(T("自訂詞彙（每行一個）", "Custom vocabulary (one per line)"), true));
        vocabularyBox = Input(settings.Vocabulary);
        vocabularyBox.Multiline = true;
        vocabularyBox.ScrollBars = ScrollBars.Vertical;
        vocabularyBox.MaxLength = 16_000;
        AddRow(panel, vocabularyBox, 92);
        AddRow(panel, TextLabel(T("Live 語音模型", "Live transcription model"), true));
        liveModelBox = Input(settings.LiveModel);
        AddRow(panel, liveModelBox, 42);
        AddRow(panel, TextLabel(T("文字整理模型", "Text cleanup model"), true));
        cleanupModelBox = Input(settings.CleanupModel);
        AddRow(panel, cleanupModelBox, 42);
        idleControls.AddRange([interfaceBox, record, languageBox, customLanguageBox, polishBox, restoreBox, vocabularyBox, liveModelBox, cleanupModelBox]);
    }

    private void BuildResults(TableLayoutPanel panel)
    {
        AddRow(panel, TextLabel(T("最近一次完成文字（僅留在記憶體）", "Last finalized result (memory only)"), true));
        resultBox = Input();
        resultBox.ReadOnly = true;
        resultBox.Multiline = true;
        resultBox.ScrollBars = ScrollBars.Vertical;
        AddRow(panel, resultBox, 165);
        copyButton = MakeButton(T("複製結果", "Copy result"), CopyResult);
        copyButton.Enabled = false;
        AddRow(panel, Buttons(copyButton, MakeButton(T("清除結果", "Clear result"), () => controller?.ClearResult())));
        AddRow(panel, TextLabel(T("無法驗證原輸入位置時，完成文字會自動複製，請自行貼上。切換輸入欄位、管理員視窗或部分編輯器可能需要此方式。", "If the original input target cannot be verified, finalized text is copied for manual paste. Changed fields, administrator windows and some editors may require this.")));
        AddRow(panel, TextLabel(T("診斷", "Diagnostics"), true));
        var preview = MakeButton(T("預覽浮動字幕", "Preview captions"), () => overlay.Present(T("字幕預覽（不錄音、不連線）", "Caption preview (no microphone or network)"), "你好，Windows! Speak naturally, in any language.", false, dismissAfterMs: 5_000));
        var connection = MakeButton(T("檢查 Gemini 連線（不錄音）", "Check Gemini connection (no mic)"), () => controller?.CheckConnection());
        var insertion = MakeButton(T("測試貼上（5 秒倒數）", "Test paste (5 second countdown)"), () => controller?.TestInsertion());
        AddRow(panel, Buttons(preview));
        AddRow(panel, Buttons(connection));
        AddRow(panel, Buttons(insertion));
        AddRow(panel, TextLabel(T("連線測試會聯絡 Google，但不開啟麥克風。貼上測試使用固定句，請在倒數期間切換到可丟棄的文字文件。", "The connection check contacts Google without opening the microphone. Paste testing uses a fixed sentence; switch to a disposable document during the countdown.")));
        idleControls.AddRange([preview, connection, insertion]);
    }

    private void InitializeServices()
    {
        if (smokeTest || controller != null) return;
        controller = new DictationController(() => settings);
        controller.Changed += RefreshState;
        controller.LevelChanged += overlay.AddLevel;
        controller.PasteDispatched += overlay.Dismiss;
        try { RegisterShortcut(); }
        catch (Exception) { ShowStatus(T("快捷鍵已被占用或無法註冊，請在辨識偏好設定其他組合。", "The shortcut is unavailable or already in use. Choose another in Preferences."), true); }
        try { keyExists = !string.IsNullOrWhiteSpace(CredentialStore.Load()); }
        catch (Exception) { ShowStatus(T("無法解密原金鑰，請重新儲存。", "The saved key could not be decrypted. Save it again."), true); }
        keyLabel.Text = KeyStatus();
        BuildTray();
        if (InitialNotice.Length > 0) ShowStatus(InitialNotice, true);
    }
    private void RegisterShortcut()
    {
        shortcut?.Dispose();
        shortcut = new GlobalShortcut();
        shortcut.Pressed += () => controller?.Press();
        shortcut.Released += duration => controller?.Release(duration);
        shortcut.UncertainRelease += () => controller?.UncertainRelease();
        shortcut.Register(settings.ShortcutModifiers, settings.ShortcutKey);
    }
    private void BuildTray()
    {
        if (tray != null) { tray.Visible = false; tray.ContextMenuStrip?.Dispose(); tray.Dispose(); }
        var menu = new ContextMenuStrip();
        menu.Items.Add(T("開啟 OpenInsert", "Open OpenInsert"), null, (_, _) => ShowMain());
        menu.Items.Add(T("完成錄音", "Finish recording"), null, (_, _) => controller?.Stop());
        menu.Items.Add(T("略過文字整理", "Skip text cleanup"), null, (_, _) => controller?.SkipCleanup());
        menu.Items.Add(T("取消本次輸入", "Cancel dictation"), null, (_, _) => controller?.Cancel());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(T("結束 OpenInsert", "Quit OpenInsert"), null, async (_, _) => await QuitAsync());
        tray = new NotifyIcon { Text = "OpenInsert — " + settings.ShortcutName, Icon = Icon, ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, _) => ShowMain();
    }
    private void ShowMain() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private async Task QuitAsync()
    {
        if (exiting) return;
        exiting = true;
        shortcut?.Dispose();
        shortcut = null;
        if (controller != null) await controller.CancelAndWaitAsync();
        Close();
    }
    private void OnClosing(object? sender, FormClosingEventArgs e)
    {
        if (exiting || smokeTest || e.CloseReason is CloseReason.WindowsShutDown or CloseReason.TaskManagerClosing)
        {
            controller?.Cancel();
            return;
        }
        e.Cancel = true;
        Hide();
    }

    private void RefreshState()
    {
        if (controller == null || IsDisposed) return;
        bool busy = controller.IsBusy;
        saveButton.Enabled = !busy;
        foreach (var control in idleControls) control.Enabled = !busy;
        customLanguageBox.Enabled = !busy && languageBox.SelectedIndex == 6;
        stopButton.Enabled = controller.State is DictationState.Preparing or DictationState.Recording;
        cancelButton.Enabled = busy;
        skipButton.Enabled = controller.State == DictationState.Polishing;
        copyButton.Enabled = !busy && controller.LastText.Length > 0;
        resultBox.Text = controller.LastText;
        ShowStatus(controller.Status, controller.LastStatusIsError);
        if (busy && !controller.Pasted)
            overlay.Present(controller.Status, controller.Preview, controller.State == DictationState.Recording, controller.LastStatusIsError);
        else if (!busy && !controller.Pasted && controller.Status.Length > 0)
            overlay.Present(controller.Status, "", false, controller.LastStatusIsError, controller.LastStatusIsError ? 10_000 : 6_000);
        if (tray != null) tray.Text = "OpenInsert — " + (busy ? T("處理中", "Active") : settings.ShortcutName);
    }
    private void ShowStatus(string text, bool error = false)
    {
        statusLabel.Text = text;
        statusLabel.ForeColor = error ? Color.FromArgb(160, 48, 40) : Color.FromArgb(57, 76, 66);
    }
    private string KeyStatus() => keyExists ? T("已儲存金鑰。欄位留空可保留現有金鑰。", "A key is saved. Leave the field blank to keep it.") : T("尚未儲存金鑰。", "No API key saved yet.");
    private void SaveKey()
    {
        try
        {
            CredentialStore.Save(GeminiApiKey.Validate(keyBox.Text));
            keyBox.Clear(); keyExists = true; keyLabel.Text = KeyStatus();
            ShowStatus(T("金鑰已加密儲存。", "API key encrypted and saved."));
        }
        catch (ArgumentException ex) { ShowStatus(ex.Message, true); }
        catch (GeminiException ex) { ShowStatus(ex.Message, true); }
        catch (Exception) { ShowStatus(T("金鑰儲存失敗，請檢查是否完整或可存取使用者資料夾。", "Could not save the key. Check the complete key and access to your user data folder."), true); }
    }
    private void DeleteKey()
    {
        try { CredentialStore.Delete(); keyExists = false; keyBox.Clear(); keyLabel.Text = KeyStatus(); ShowStatus(T("已刪除儲存的金鑰。", "Saved API key deleted.")); }
        catch (Exception) { ShowStatus(T("無法刪除金鑰。", "Could not delete the saved key."), true); }
    }
    private void SaveSettings()
    {
        var old = settings;
        bool registered = false;
        try
        {
            var next = settings with
            {
                InterfaceLanguage = interfaceBox.SelectedIndex == 1 ? "en" : "zh-Hant",
                WritingLanguage = AppSettings.LanguageIds[languageBox.SelectedIndex],
                CustomLanguage = customLanguageBox.Text, Vocabulary = vocabularyBox.Text,
                LiveModel = liveModelBox.Text.Trim(), CleanupModel = cleanupModelBox.Text.Trim(),
                CloudConsent = consentBox.Checked, Polish = polishBox.Checked, RestoreClipboard = restoreBox.Checked,
                ShortcutModifiers = pendingModifiers, ShortcutKey = pendingKey
            };
            next.Validate();
            shortcut?.Register(next.ShortcutModifiers, next.ShortcutKey);
            registered = true;
            next.Save();
            settings = next;
            bool relocalize = old.InterfaceLanguage != next.InterfaceLanguage;
            if (relocalize) { BuildInterface(); BuildTray(); }
            if (tray != null) tray.Text = "OpenInsert — " + settings.ShortcutName;
            ShowStatus(T("設定已儲存。", "Settings saved."));
        }
        catch (Exception ex)
        {
            if (registered)
            {
                try { shortcut?.Register(old.ShortcutModifiers, old.ShortcutKey); }
                catch { ShowStatus(T("儲存失敗，且無法還原快捷鍵。請重新選擇快捷鍵。", "Saving failed and the old shortcut could not be restored. Select it again."), true); return; }
            }
            ShowStatus(ex is ArgumentException ? ex.Message : T("無法儲存：請檢查快捷鍵是否衝突及設定資料夾權限。", "Could not save. Check shortcut conflicts and settings folder access."), true);
        }
    }
    private void RecordShortcut()
    {
        if (controller?.IsBusy == true) return;
        // Let the recorder receive even the currently assigned key; a registered OS hotkey
        // would otherwise consume it and start dictation inside this modal dialog.
        shortcut?.Dispose();
        shortcut = null;
        using var dialog = new ShortcutRecorderDialog(Chinese);
        try
        {
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            pendingModifiers = dialog.Modifiers;
            pendingKey = dialog.VirtualKey;
            shortcutLabel.Text = ShortcutRecorderDialog.Format(pendingModifiers, pendingKey) + T("（儲存後套用）", " (save to apply)");
        }
        finally
        {
            try { RegisterShortcut(); }
            catch { ShowStatus(T("無法還原快捷鍵，請選擇其他組合並儲存。", "The shortcut could not be restored. Choose another combination and save."), true); }
        }
    }
    private void CopyResult()
    {
        if (controller == null || controller.LastText.Length == 0) return;
        try { Clipboard.SetText(controller.LastText); ShowStatus(T("已複製結果。", "Result copied.")); }
        catch (Exception) { ShowStatus(T("剪貼簿忙碌，請稍後重試。", "The clipboard is busy. Try again."), true); }
    }
    private void OpenLink(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception) { ShowStatus(T("無法開啟連結或 Windows 設定。", "Could not open the link or Windows settings."), true); }
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            shortcut?.Dispose();
            controller?.Dispose();
            overlay.Dispose();
            if (tray != null) { tray.Visible = false; tray.ContextMenuStrip?.Dispose(); tray.Dispose(); }
        }
        base.Dispose(disposing);
    }
}
