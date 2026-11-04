// SimPilot Bridge launcher: a small window + tray icon around node.exe / bridge.cjs.
// Compiled in CI with the C# 5 compiler that ships with Windows (csc.exe, .NET Framework 4), so keep to C# 5:
// no string interpolation, no ?. operator, no expression-bodied members.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program
{
    public const int Port = 8386;

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

    [STAThread]
    static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--check") >= 0) return SelfCheck();
        bool created;
        using (Mutex single = new Mutex(true, "Local\\SimPilotBridgeLauncher", out created))
        {
            if (!created)
            {
                MessageBox.Show("SimPilot Bridge is already running. Look for its icon near the clock (click ^ if it is hidden).",
                    "SimPilot Bridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }
            try { SetProcessDPIAware(); } catch (Exception) { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            MainForm form = new MainForm(Array.IndexOf(args, "--minimized") >= 0);
            form.Begin();
            Application.Run(form);
        }
        return 0;
    }

    // CI runs this after compiling: proves the exe starts and its JSON/network helpers work, without opening a window.
    static int SelfCheck()
    {
        try
        {
            object parsed = new JavaScriptSerializer().DeserializeObject("{\"sim\":{\"connected\":true},\"bridge\":{\"apps\":2}}");
            if (!Json.Bool(parsed, "sim", "connected") || Json.Int(parsed, "bridge", "apps") != 2) return 1;
            Net.Addresses();
            return 0;
        }
        catch (Exception) { return 1; }
    }
}

static class Json
{
    public static object Get(object root, params string[] path)
    {
        object cur = root;
        foreach (string key in path)
        {
            Dictionary<string, object> d = cur as Dictionary<string, object>;
            if (d == null || !d.ContainsKey(key)) return null;
            cur = d[key];
        }
        return cur;
    }
    public static bool Bool(object root, params string[] path) { object v = Get(root, path); return v is bool && (bool)v; }
    public static int Int(object root, params string[] path)
    {
        object v = Get(root, path);
        return v is int ? (int)v : 0;
    }
    public static string Str(object root, params string[] path) { object v = Get(root, path); return v as string; }
}

static class Net
{
    /// Plain HTTP to the local bridge. Throws with the bridge's own error message when it answers with one.
    public static string Request(string method, string path, int timeoutMs)
    {
        HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + Program.Port + path);
        r.Method = method;
        r.Timeout = timeoutMs;
        r.ReadWriteTimeout = timeoutMs;
        r.Proxy = null;
        if (method == "POST") r.ContentLength = 0;
        try
        {
            using (HttpWebResponse res = (HttpWebResponse)r.GetResponse())
                return Read(res);
        }
        catch (WebException ex)
        {
            HttpWebResponse res = ex.Response as HttpWebResponse;
            if (res == null) throw;
            string body = Read(res);
            string message = null;
            try { message = Json.Str(new JavaScriptSerializer().DeserializeObject(body), "error"); } catch (Exception) { }
            throw new Exception(message ?? ("The bridge answered " + (int)res.StatusCode));
        }
    }

    static string Read(HttpWebResponse res)
    {
        using (StreamReader sr = new StreamReader(res.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
    }

    /// The PC's LAN addresses as "ip:port", Wi-Fi/Ethernet first and VPN/virtual adapters last.
    public static List<string> Addresses()
    {
        List<KeyValuePair<int, string>> found = new List<KeyValuePair<int, string>>();
        foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            int rank = Regex.IsMatch(nic.Name + " " + nic.Description, "vpn|virtual|vethernet|vmware|wsl|tun|docker|hyper-v|tap", RegexOptions.IgnoreCase) ? 1 : 0;
            foreach (UnicastIPAddressInformation ip in nic.GetIPProperties().UnicastAddresses)
                if (ip.Address.AddressFamily == AddressFamily.InterNetwork && !ip.Address.ToString().StartsWith("169.254."))
                    found.Add(new KeyValuePair<int, string>(rank, ip.Address + ":" + Program.Port));
        }
        found.Sort(delegate (KeyValuePair<int, string> a, KeyValuePair<int, string> b) { return a.Key.CompareTo(b.Key); });
        List<string> result = new List<string>();
        foreach (KeyValuePair<int, string> f in found) result.Add(f.Value);
        return result;
    }
}

class MainForm : Form
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "SimPilot Bridge";

    readonly string dir = AppDomain.CurrentDomain.BaseDirectory;
    readonly bool startHidden;
    bool allowShow;
    bool quitting;
    bool updating;
    bool polling;
    bool trayTipShown;
    Process node;

    Label title, ipad, sim, panel, addresses;
    CheckBox autostart;
    TextBox log;
    Button check, chart, quit, restart;
    NotifyIcon tray;
    System.Windows.Forms.Timer timer;

    public MainForm(bool minimized)
    {
        startHidden = minimized;
        Text = "SimPilot Bridge";
        Font = new Font("Segoe UI", 9F);
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(540, 460);
        MinimumSize = new Size(480, 380);
        StartPosition = FormStartPosition.CenterScreen;
        Icon appIcon = null;
        try { appIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }
        if (appIcon != null) Icon = appIcon;

        title = new Label { Text = "SimPilot Bridge", Font = new Font("Segoe UI", 15F, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 0, 0, 6) };
        ipad = StatusLabel("iPad: starting...");
        sim = StatusLabel("MSFS 2024: waiting");
        panel = StatusLabel("Chart panel (SimPilot Link): not connected");
        addresses = new Label { AutoSize = true, MaximumSize = new Size(500, 0), Margin = new Padding(0, 8, 0, 4) };
        autostart = new CheckBox { Text = "Start with Windows (hidden in the tray)", AutoSize = true, Checked = AutostartOn() };
        autostart.CheckedChanged += delegate { SetAutostart(autostart.Checked); };

        FlowLayoutPanel top = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(12, 12, 12, 4) };
        top.Controls.AddRange(new Control[] { title, ipad, sim, panel, addresses, autostart });

        log = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 8.5F), Margin = new Padding(12, 4, 12, 4), BackColor = Color.White };

        check = new Button { Text = "Check for updates", AutoSize = true, Padding = new Padding(8, 3, 8, 3) };
        check.Click += delegate { CheckForUpdates(); };
        chart = new Button { Text = "Chart panel installer...", AutoSize = true, Padding = new Padding(8, 3, 8, 3) };
        chart.Click += delegate { OpenChartPanelFolder(); };
        restart = new Button { Text = "Restart bridge", AutoSize = true, Padding = new Padding(8, 3, 8, 3), Visible = false };
        restart.Click += delegate { restart.Visible = false; StartBridge(); };
        quit = new Button { Text = "Quit", AutoSize = true, Padding = new Padding(8, 3, 8, 3) };
        quit.Click += delegate { Quit(); };
        FlowLayoutPanel buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, Dock = DockStyle.Fill, Padding = new Padding(8, 4, 8, 8) };
        buttons.Controls.AddRange(new Control[] { check, chart, restart, quit });

        TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(top, 0, 0);
        layout.Controls.Add(log, 0, 1);
        layout.Controls.Add(buttons, 0, 2);
        Controls.Add(layout);

        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Open", null, delegate { ShowWindow(); });
        menu.Items.Add("Check for updates", null, delegate { ShowWindow(); CheckForUpdates(); });
        menu.Items.Add("Quit", null, delegate { Quit(); });
        tray = new NotifyIcon { Text = "SimPilot Bridge", Icon = appIcon ?? SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += delegate { ShowWindow(); };

        timer = new System.Windows.Forms.Timer { Interval = 2000 };
        timer.Tick += delegate { Poll(); };
    }

    // The window stays hidden until ShowWindow() when started with --minimized.
    protected override void SetVisibleCore(bool value)
    {
        if (!allowShow) value = false;
        base.SetVisibleCore(value);
    }

    public void Begin()
    {
        IntPtr handle = Handle;   // create the window now so background threads can BeginInvoke even while hidden
        addresses.Text = AddressText();
        if (!startHidden) ShowWindow();
        StartBridge();
        timer.Start();
    }

    void ShowWindow()
    {
        allowShow = true;
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!quitting && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            if (!trayTipShown)
            {
                trayTipShown = true;
                tray.ShowBalloonTip(4000, "SimPilot Bridge is still running", "Right-click the tray icon to quit it.", ToolTipIcon.Info);
            }
            return;
        }
        base.OnFormClosing(e);
    }

    static Label StatusLabel(string text) { return new Label { Text = text, AutoSize = true, Margin = new Padding(0, 2, 0, 2), ForeColor = Color.DimGray }; }

    string AddressText()
    {
        List<string> list = Net.Addresses();
        if (list.Count == 0) return "No network found. Connect the PC to the same Wi-Fi or Ethernet as the iPad.";
        return "The iPad finds this PC by itself. If it doesn't, type one of these in the app under Settings > Bridge:\r\n  " + string.Join("\r\n  ", list.ToArray());
    }

    // ---- bridge process ----

    void StartBridge()
    {
        string exe = Path.Combine(dir, "node.exe");
        string script = Path.Combine(dir, "bridge.cjs");
        if (!File.Exists(exe) || !File.Exists(script))
        {
            AppendLog("node.exe or bridge.cjs is missing next to this program. Extract the whole SimPilot for PC folder and run it from there.");
            restart.Visible = true;
            return;
        }
        KillStrays(exe);
        ProcessStartInfo psi = new ProcessStartInfo(exe, "\"" + script + "\"");
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        try
        {
            node = new Process { StartInfo = psi, EnableRaisingEvents = true };
            node.OutputDataReceived += delegate (object s, DataReceivedEventArgs a) { if (a.Data != null) AppendLog(a.Data); };
            node.ErrorDataReceived += delegate (object s, DataReceivedEventArgs a) { if (a.Data != null) AppendLog(a.Data); };
            node.Exited += OnNodeExited;
            node.Start();
            node.BeginOutputReadLine();
            node.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            AppendLog("Couldn't start the bridge: " + ex.Message);
            restart.Visible = true;
        }
    }

    // A previous launcher that crashed can leave its bridge running and holding the port.
    static void KillStrays(string exe)
    {
        try
        {
            foreach (Process p in Process.GetProcessesByName("node"))
            {
                try { if (string.Equals(p.MainModule.FileName, exe, StringComparison.OrdinalIgnoreCase)) { p.Kill(); p.WaitForExit(3000); } }
                catch (Exception) { }
            }
        }
        catch (Exception) { }
    }

    void OnNodeExited(object sender, EventArgs e)
    {
        int code = 1;
        try { code = node.ExitCode; } catch (Exception) { }
        BeginInvoke(new MethodInvoker(delegate
        {
            // Exit code 0 only happens when the bridge shut itself down to install an update.
            if (quitting || updating || code == 0) { Quit(); return; }
            AppendLog("SimPilot Bridge stopped (exit code " + code + ").");
            ipad.Text = "Bridge stopped";
            restart.Visible = true;
            ShowWindow();
        }));
    }

    void Quit()
    {
        if (quitting) return;
        quitting = true;
        timer.Stop();
        try { if (node != null && !node.HasExited) node.Kill(); } catch (Exception) { }
        tray.Visible = false;
        tray.Dispose();
        Application.Exit();
    }

    // ---- status ----

    void Poll()
    {
        if (polling || quitting) return;
        polling = true;
        ThreadPool.QueueUserWorkItem(delegate
        {
            object status = null;
            try { status = new JavaScriptSerializer().DeserializeObject(Net.Request("GET", "/api/status", 1500)); } catch (Exception) { }
            try { BeginInvoke(new MethodInvoker(delegate { polling = false; ShowStatus(status); })); } catch (Exception) { polling = false; }
        });
    }

    void ShowStatus(object s)
    {
        if (s == null) { if (restart.Visible) return; ipad.Text = "Bridge starting..."; return; }
        int apps = Json.Int(s, "bridge", "apps");
        bool simOn = Json.Bool(s, "sim", "connected");
        bool linkOn = Json.Bool(s, "link", "connected");
        string title2 = Json.Str(s, "sim", "aircraftTitle");
        string version = Json.Str(s, "bridge", "version");
        if (version != null) title.Text = "SimPilot Bridge " + version;
        Set(ipad, apps > 0, apps > 0 ? "iPad: connected" + (apps > 1 ? " (" + apps + ")" : "") : "iPad: waiting for the app");
        Set(sim, simOn, simOn ? "MSFS 2024: connected" + (string.IsNullOrEmpty(title2) ? "" : " - " + title2) : "MSFS 2024: waiting (start the sim)");
        Set(panel, linkOn, linkOn ? "Chart panel (SimPilot Link): connected" : "Chart panel (SimPilot Link): not connected (optional)");
        tray.Text = "SimPilot Bridge - iPad " + (apps > 0 ? "connected" : "waiting") + ", MSFS " + (simOn ? "connected" : "waiting");
    }

    static void Set(Label l, bool ok, string text) { l.Text = text; l.ForeColor = ok ? Color.FromArgb(0, 140, 60) : Color.DimGray; }

    void AppendLog(string line)
    {
        try
        {
            BeginInvoke(new MethodInvoker(delegate
            {
                if (log.TextLength > 30000) log.Text = log.Text.Substring(log.TextLength - 15000);
                log.AppendText(line + "\r\n");
            }));
        }
        catch (Exception) { }
    }

    // ---- actions ----

    void CheckForUpdates()
    {
        check.Enabled = false;
        ThreadPool.QueueUserWorkItem(delegate
        {
            string message = null;
            bool canInstall = false;
            string latest = null;
            try
            {
                object info = new JavaScriptSerializer().DeserializeObject(Net.Request("GET", "/bridge/update", 20000));
                message = Json.Str(info, "notes");
                canInstall = Json.Bool(info, "canInstall");
                latest = Json.Str(info, "latest");
            }
            catch (Exception ex) { message = "Couldn't check for updates: " + ex.Message; }
            BeginInvoke(new MethodInvoker(delegate
            {
                check.Enabled = true;
                if (canInstall && MessageBox.Show(this, message + "\r\n\r\nLatest: " + latest + "\r\n\r\nInstall it now? SimPilot Bridge restarts by itself.",
                        "SimPilot Bridge", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) InstallUpdate();
                else if (!canInstall) MessageBox.Show(this, message, "SimPilot Bridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }));
        });
    }

    void InstallUpdate()
    {
        check.Enabled = false;
        AppendLog("Downloading the update...");
        ThreadPool.QueueUserWorkItem(delegate
        {
            string error = null;
            try { Net.Request("POST", "/bridge/update", 330000); } catch (Exception ex) { error = ex.Message; }
            BeginInvoke(new MethodInvoker(delegate
            {
                if (error == null) { updating = true; AppendLog("Installing the update. This window closes and SimPilot Bridge opens again."); return; }
                check.Enabled = true;
                AppendLog("Update failed: " + error);
                MessageBox.Show(this, "The update failed: " + error, "SimPilot Bridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }));
        });
    }

    void OpenChartPanelFolder()
    {
        string folder = Path.Combine(dir, "Chart panel (optional)");
        if (!Directory.Exists(folder))
        {
            MessageBox.Show(this, "The chart panel folder wasn't found next to this program. Use the full SimPilot-for-PC.zip download.",
                "SimPilot Bridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        MessageBox.Show(this, "Close MSFS 2024, then double-click \"Install SimPilot Link\" in the folder that opens.\r\nRead me.txt has the full steps.",
            "SimPilot Bridge", MessageBoxButtons.OK, MessageBoxIcon.Information);
        Process.Start("explorer.exe", "\"" + folder + "\"");
    }

    static bool AutostartOn()
    {
        try { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(RunName) != null; }
        catch (Exception) { return false; }
    }

    static void SetAutostart(bool on)
    {
        try
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(RunName, "\"" + Application.ExecutablePath + "\" --minimized");
                else k.DeleteValue(RunName, false);
            }
        }
        catch (Exception) { }
    }
}
