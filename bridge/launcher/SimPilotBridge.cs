// SimPilot Bridge.exe: tray icon + the bridge window around node.exe / bridge.cjs.
// The window itself is the page the bridge serves at http://127.0.0.1:8386/, opened as a chromeless Edge/Chrome app window.
// Compiled in CI with the C# 5 compiler that ships with Windows (csc.exe, .NET Framework 4), so keep to C# 5:
// no string interpolation, no ?. operator, no expression-bodied members.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

static class Program
{
    public const int Port = 8386;

    [STAThread]
    static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--check") >= 0) return SelfCheck();
        bool created;
        using (Mutex single = new Mutex(true, "Local\\SimPilotBridgeLauncher", out created))
        {
            if (!created)
            {
                Window.Open();   // already running: just bring the window back
                return 0;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            TrayApp app = new TrayApp(Array.IndexOf(args, "--minimized") >= 0);
            app.Begin();
            Application.Run(app);
        }
        return 0;
    }

    // CI runs this after compiling: proves the exe starts and its JSON helper works, without opening anything.
    static int SelfCheck()
    {
        try
        {
            object parsed = new JavaScriptSerializer().DeserializeObject("{\"sim\":{\"connected\":true},\"bridge\":{\"apps\":2}}");
            return Json.Bool(parsed, "sim", "connected") && Json.Int(parsed, "bridge", "apps") == 2 ? 0 : 1;
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
    public static int Int(object root, params string[] path) { object v = Get(root, path); return v is int ? (int)v : 0; }
}

static class Window
{
    static readonly string Url = "http://127.0.0.1:" + Program.Port + "/";

    /// Edge ships with Windows 10/11, so use it (or Chrome) as an app window with no tabs or address bar; any browser otherwise.
    public static void Open()
    {
        string[] roots = { Environment.GetEnvironmentVariable("ProgramFiles(x86)"), Environment.GetEnvironmentVariable("ProgramFiles"), Environment.GetEnvironmentVariable("LocalAppData") };
        string[] relative = { @"Microsoft\Edge\Application\msedge.exe", @"Google\Chrome\Application\chrome.exe" };
        string profile = Path.Combine(Environment.GetEnvironmentVariable("LocalAppData") ?? "", @"SimPilot Bridge\window");
        foreach (string rel in relative)
            foreach (string root in roots)
            {
                if (string.IsNullOrEmpty(root)) continue;
                string exe = Path.Combine(root, rel);
                if (!File.Exists(exe)) continue;
                try
                {
                    Process.Start(new ProcessStartInfo(exe, "--app=" + Url + " --window-size=1040,680 --no-first-run --user-data-dir=\"" + profile + "\"") { UseShellExecute = false });
                    return;
                }
                catch (Exception) { }
            }
        try { Process.Start(Url); } catch (Exception) { }
    }
}

static class Net
{
    /// Plain GET to the local bridge; throws on any failure.
    public static string Get(string path, int timeoutMs)
    {
        HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + Program.Port + path);
        r.Timeout = timeoutMs;
        r.ReadWriteTimeout = timeoutMs;
        r.Proxy = null;
        using (HttpWebResponse res = (HttpWebResponse)r.GetResponse())
        using (StreamReader sr = new StreamReader(res.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
    }
}

class TrayApp : ApplicationContext
{
    readonly string dir = AppDomain.CurrentDomain.BaseDirectory;
    readonly bool startHidden;
    readonly Control ui = new Control();
    readonly NotifyIcon tray;
    readonly ToolStripMenuItem restart;
    readonly System.Windows.Forms.Timer timer;
    bool quitting;
    bool polling;
    Process node;

    public TrayApp(bool minimized)
    {
        startHidden = minimized;
        Icon icon = null;
        try { icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch (Exception) { }
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Open SimPilot Bridge", null, delegate { Window.Open(); });
        restart = new ToolStripMenuItem("Restart bridge", null, delegate { StartBridge(); }) { Visible = false };
        menu.Items.Add(restart);
        menu.Items.Add("Quit", null, delegate { Quit(); });
        tray = new NotifyIcon { Text = "SimPilot Bridge", Icon = icon ?? SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += delegate { Window.Open(); };
        timer = new System.Windows.Forms.Timer { Interval = 3000 };
        timer.Tick += delegate { Poll(); };
    }

    public void Begin()
    {
        IntPtr handle = ui.Handle;   // create it now so background threads can BeginInvoke
        StartBridge();
        timer.Start();
        if (!startHidden) OpenWhenReady();
    }

    void OpenWhenReady()
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            for (int i = 0; i < 40 && !quitting; i++)
            {
                try { Net.Get("/api/status", 1000); break; } catch (Exception) { Thread.Sleep(500); }
            }
            if (!quitting) Window.Open();
        });
    }

    // ---- bridge process ----

    void StartBridge()
    {
        string exe = Path.Combine(dir, "node.exe");
        string script = Path.Combine(dir, "bridge.cjs");
        if (!File.Exists(exe) || !File.Exists(script))
        {
            MessageBox.Show("node.exe or bridge.cjs is missing next to this program. Extract the whole SimPilot for PC folder and run it from there.", "SimPilot Bridge", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            Quit();
            return;
        }
        KillStrays(exe);
        restart.Visible = false;
        ProcessStartInfo psi = new ProcessStartInfo(exe, "\"" + script + "\"");
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        try
        {
            node = new Process { StartInfo = psi, EnableRaisingEvents = true };
            node.Exited += OnNodeExited;
            node.Start();
        }
        catch (Exception ex) { Stopped("Couldn't start the bridge: " + ex.Message); }
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
        ui.BeginInvoke(new MethodInvoker(delegate
        {
            // Exit code 0 is the bridge shutting itself down for an update or an uninstall.
            if (quitting || code == 0) { Quit(); return; }
            Stopped("SimPilot Bridge stopped (exit code " + code + "). Use Restart bridge in the tray menu.");
        }));
    }

    void Stopped(string message)
    {
        restart.Visible = true;
        tray.Text = "SimPilot Bridge - stopped";
        tray.ShowBalloonTip(6000, "SimPilot Bridge", message, ToolTipIcon.Warning);
    }

    void Quit()
    {
        if (quitting) return;
        quitting = true;
        timer.Stop();
        try { if (node != null && !node.HasExited) node.Kill(); } catch (Exception) { }
        tray.Visible = false;
        tray.Dispose();
        ExitThread();
    }

    // ---- tray tooltip ----

    void Poll()
    {
        if (polling || quitting || restart.Visible) return;
        polling = true;
        ThreadPool.QueueUserWorkItem(delegate
        {
            object status = null;
            try { status = new JavaScriptSerializer().DeserializeObject(Net.Get("/api/status", 1500)); } catch (Exception) { }
            try { ui.BeginInvoke(new MethodInvoker(delegate { polling = false; ShowStatus(status); })); } catch (Exception) { polling = false; }
        });
    }

    void ShowStatus(object s)
    {
        if (s == null || quitting) return;
        bool ipad = Json.Int(s, "bridge", "apps") > 0;
        bool sim = Json.Bool(s, "sim", "connected");
        tray.Text = "SimPilot Bridge - iPad " + (ipad ? "connected" : "waiting") + ", MSFS " + (sim ? "connected" : "waiting");
    }
}
