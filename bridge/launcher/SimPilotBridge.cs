// SimPilot Bridge.exe: a native WPF window plus a tray icon around node.exe / bridge.cjs.
// Compiled in CI with the C# 5 compiler that ships with Windows (csc.exe, .NET Framework 4), so keep to C# 5:
// no string interpolation, no ?. operator, no expression-bodied members, no nameof.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;
using Shapes = System.Windows.Shapes;

static class Program
{
    public const int Port = 8386;
    const string ShowEvent = "Local\\SimPilotBridgeShow";

    [STAThread]
    static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--check") >= 0) return SelfCheck();
        bool created;
        using (Mutex single = new Mutex(true, "Local\\SimPilotBridgeLauncher", out created))
        {
            if (!created)
            {
                try { EventWaitHandle.OpenExisting(ShowEvent).Set(); } catch (Exception) { }   // already running: show its window
                return 0;
            }
            Application app = new Application();
            app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            TrayApp tray = new TrayApp(Array.IndexOf(args, "--minimized") >= 0, new EventWaitHandle(false, EventResetMode.AutoReset, ShowEvent));
            app.Startup += delegate { tray.Begin(); };
            app.Run();
        }
        return 0;
    }

    // CI runs this after compiling: builds the whole window (not shown) and feeds it sample data, so a broken UI fails the build.
    static int SelfCheck()
    {
        int result = 1;
        Thread t = new Thread(delegate ()
        {
            try
            {
                JavaScriptSerializer js = new JavaScriptSerializer();
                object status = js.DeserializeObject("{\"sim\":{\"connected\":true,\"aircraftTitle\":\"Fenix A320\"},\"link\":{\"connected\":false},\"bridge\":{\"apps\":2,\"version\":\"0.1.1\",\"port\":8386}}");
                object info = js.DeserializeObject("{\"cache\":{\"airports\":[{\"icao\":\"EGSS\",\"charts\":14,\"bytes\":123456789}],\"bytes\":123456789}}");
                object log = js.DeserializeObject("{\"entries\":[{\"time\":\"2026-11-04T16:42:01.123Z\",\"level\":\"warn\",\"scope\":\"sim\",\"message\":\"in-sim link lost\"}]}");
                if (!Json.Bool(status, "sim", "connected") || Json.Int(status, "bridge", "apps") != 2) return;
                MainWindow w = new MainWindow(null);
                w.ApplyStatus(status);
                w.ApplyInfo(info);
                w.ApplyLog(log);
                w.ShowPage(3);
                w.ShowPage(4);
                w.OpenWizard();
                result = 0;
            }
            catch (Exception ex) { Console.Error.WriteLine(ex.ToString()); }
        });
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        t.Join();
        return result;
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
    public static int Int(object root, params string[] path) { return (int)Long(root, path); }
    public static long Long(object root, params string[] path)
    {
        object v = Get(root, path);
        return v is IConvertible && !(v is string) && !(v is bool) ? Convert.ToInt64(v, CultureInfo.InvariantCulture) : 0;
    }
    public static string Str(object root, params string[] path) { return Get(root, path) as string; }
    public static IEnumerable List(object root, params string[] path)
    {
        IEnumerable list = Get(root, path) as IEnumerable;
        return list == null || list is string ? new object[0] : list;
    }
}

static class Net
{
    /// Plain HTTP to the bridge running in this same program. Throws with the bridge's own error message when it gives one.
    public static string Call(string method, string path, int timeoutMs)
    {
        HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + Program.Port + path);
        r.Method = method;
        r.Timeout = timeoutMs;
        r.ReadWriteTimeout = timeoutMs;
        r.Proxy = null;
        if (method == "POST") { r.ContentLength = 0; r.Headers["x-simpilot-ui"] = "1"; }   // the bridge only accepts repairs from this window
        try
        {
            using (HttpWebResponse res = (HttpWebResponse)r.GetResponse()) return Read(res);
        }
        catch (WebException ex)
        {
            HttpWebResponse res = ex.Response as HttpWebResponse;
            if (res == null) throw;
            string message = null;
            try { message = Json.Str(new JavaScriptSerializer().DeserializeObject(Read(res)), "error"); } catch (Exception) { }
            throw new Exception(message ?? ("The bridge answered " + (int)res.StatusCode));
        }
    }

    static string Read(HttpWebResponse res)
    {
        using (StreamReader sr = new StreamReader(res.GetResponseStream(), Encoding.UTF8)) return sr.ReadToEnd();
    }

    public static object Obj(string method, string path, int timeoutMs) { return new JavaScriptSerializer().DeserializeObject(Call(method, path, timeoutMs)); }
}

// ---- look: the iOS app's night colours ----
static class Pal
{
    public static Color C(string hex) { return (Color)ColorConverter.ConvertFromString(hex); }
    public static SolidColorBrush B(string hex) { return new SolidColorBrush(C(hex)); }   // new each time: animated brushes can't be shared
    public const string Frame = "#22252B", Panel = "#2B2E34", Line = "#3A3D44", Hover = "#2E3138", Hover2 = "#363A42";
    public const string Fg = "#FFFFFF", Fg2 = "#9EA3AB", Fg3 = "#6B7079", Ok = "#2FB24F", Blue = "#3D8BFF", BlueHover = "#5A9DFF", Warn = "#E8913A", Bad = "#FF6B6B";
    public static readonly FontFamily Sans = new FontFamily("Segoe UI"), Mono = new FontFamily("Consolas");

    public static TextBlock Text(string text, double size, string fg, bool bold)
    {
        TextBlock t = new TextBlock { Text = text, FontSize = size, Foreground = B(fg), FontFamily = Sans, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        if (bold) t.FontWeight = FontWeights.SemiBold;
        return t;
    }

    public static Shapes.Path Icon(string data, string stroke)
    {
        return new Shapes.Path { Data = Geometry.Parse(data), Stroke = B(stroke), StrokeThickness = 1.5, Width = 16, Height = 16, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, StrokeLineJoin = PenLineJoin.Round };
    }

    static IEasingFunction Ease() { return new CubicEase { EasingMode = EasingMode.EaseOut }; }

    public static void Fade(UIElement e, double to, int ms)
    {
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = Ease() });
    }

    public static void Tint(SolidColorBrush b, string hex, int ms)
    {
        b.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(C(hex), TimeSpan.FromMilliseconds(ms)));
    }

    public static void Slide(TranslateTransform t, DependencyProperty p, double from, double to, int ms)
    {
        t.BeginAnimation(p, new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms)) { EasingFunction = Ease() });
    }
}

/// A rounded button that eases between colours on hover and shrinks a little when pressed.
class Btn : Border
{
    public event Action Click;
    readonly SolidColorBrush fill = Pal.B("#00000000");
    readonly SolidColorBrush edge = Pal.B(Pal.Line);
    readonly TextBlock label;
    readonly string kind;   // ghost | primary | danger | icon | flat
    readonly string idle, over;
    readonly ScaleTransform press = new ScaleTransform(1, 1);

    public Btn(string text, string kind)
    {
        this.kind = kind;
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        Padding = new Thickness(14, 7, 14, 7);
        Cursor = Cursors.Hand;
        Background = fill;
        BorderBrush = edge;
        RenderTransform = press;
        RenderTransformOrigin = new Point(0.5, 0.5);
        string fg = kind == "primary" ? Pal.Fg : kind == "danger" ? Pal.Bad : Pal.Fg2;
        if (kind == "primary") { idle = Pal.Blue; over = Pal.BlueHover; fill.Color = Pal.C(idle); edge.Color = Pal.C(idle); }
        else { idle = "#00000000"; over = Pal.Hover2; }
        label = Pal.Text(text, 13.5, fg, kind == "primary");
        Child = label;
        MouseEnter += delegate { if (IsEnabled) { Pal.Tint(fill, over, 140); if (kind != "primary") Pal.Tint(label.Foreground as SolidColorBrush, kind == "danger" ? "#FF8A8A" : Pal.Fg, 140); } };
        MouseLeave += delegate { Pal.Tint(fill, idle, 180); if (kind != "primary") Pal.Tint(label.Foreground as SolidColorBrush, kind == "danger" ? Pal.Bad : Pal.Fg2, 180); };
        MouseLeftButtonDown += delegate { if (IsEnabled) Pal.Tint(fill, over, 40); press.ScaleX = press.ScaleY = 0.97; CaptureMouse(); };
        MouseLeftButtonUp += delegate
        {
            bool inside = IsMouseOver;
            press.ScaleX = press.ScaleY = 1;
            ReleaseMouseCapture();
            if (inside && IsEnabled && Click != null) Click();
        };
        IsEnabledChanged += delegate { Opacity = IsEnabled ? 1 : 0.5; };
    }

    public string Text { get { return label.Text; } set { label.Text = value; } }
    public void SetContent(UIElement e) { Child = e; }
}

/// Status dot; while connected a soft ring pulses around it.
class Dot : Grid
{
    readonly Shapes.Ellipse core = new Shapes.Ellipse { Width = 8, Height = 8, Fill = Pal.B(Pal.Fg3) };
    readonly Shapes.Ellipse ring = new Shapes.Ellipse { Width = 8, Height = 8, Fill = Pal.B(Pal.Ok), Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
    readonly ScaleTransform scale = new ScaleTransform(1, 1);
    bool pulsing;

    public Dot()
    {
        Width = 18; Height = 18;
        ring.RenderTransform = scale;
        Children.Add(ring);
        Children.Add(core);
    }

    public void Set(bool ok, bool busy)
    {
        Pal.Tint((SolidColorBrush)core.Fill, ok ? Pal.Ok : busy ? Pal.Blue : Pal.Fg3, 300);
        Pal.Tint((SolidColorBrush)ring.Fill, busy ? Pal.Blue : Pal.Ok, 300);
        bool want = ok || busy;
        if (want == pulsing) return;
        pulsing = want;
        if (!want)
        {
            ring.BeginAnimation(UIElement.OpacityProperty, null); scale.BeginAnimation(ScaleTransform.ScaleXProperty, null); scale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            ring.Opacity = 0;
            return;
        }
        Duration d = new Duration(TimeSpan.FromMilliseconds(2200));
        DoubleAnimation grow = new DoubleAnimation(1, 2.4, d) { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        ring.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.45, 0, d) { RepeatBehavior = RepeatBehavior.Forever });
    }
}

class Switch : Border
{
    public event Action Changed;
    readonly SolidColorBrush track = Pal.B(Pal.Line);
    readonly Shapes.Ellipse thumb = new Shapes.Ellipse { Width = 12, Height = 12, Fill = Pal.B(Pal.Fg2), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
    readonly TranslateTransform move = new TranslateTransform(3, 0);
    bool on;

    public Switch()
    {
        Width = 32; Height = 18; CornerRadius = new CornerRadius(9); Background = track; Cursor = Cursors.Hand;
        thumb.RenderTransform = move;
        Child = thumb;
        MouseLeftButtonUp += delegate { Set(!on, true); if (Changed != null) Changed(); };
    }

    public bool On { get { return on; } }

    public void Set(bool value, bool animate)
    {
        on = value;
        int ms = animate ? 180 : 1;
        Pal.Tint(track, on ? Pal.Blue : Pal.Line, ms);
        Pal.Tint((SolidColorBrush)thumb.Fill, on ? Pal.Fg : Pal.Fg2, ms);
        Pal.Slide(move, TranslateTransform.XProperty, move.X, on ? 17 : 3, ms);
    }
}

class NavItem : Border
{
    public event Action Click;
    readonly SolidColorBrush fill = Pal.B("#00000000");
    readonly SolidColorBrush fg = Pal.B(Pal.Fg2);
    bool selected;

    public NavItem(string text, string iconData)
    {
        CornerRadius = new CornerRadius(8); Padding = new Thickness(12, 9, 12, 9); Cursor = Cursors.Hand; Background = fill;
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(27) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        Shapes.Path icon = new Shapes.Path { Data = Geometry.Parse(iconData), Stroke = fg, StrokeThickness = 1.5, Width = 16, Height = 16, StrokeLineJoin = PenLineJoin.Round, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        TextBlock t = new TextBlock { Text = text, FontSize = 14, FontFamily = Pal.Sans, Foreground = fg, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(t, 1);
        g.Children.Add(icon); g.Children.Add(t);
        Child = g;
        MouseEnter += delegate { if (!selected) { Pal.Tint(fill, "#1F2227", 120); Pal.Tint(fg, Pal.Fg, 120); } };
        MouseLeave += delegate { if (!selected) { Pal.Tint(fill, "#00000000", 160); Pal.Tint(fg, Pal.Fg2, 160); } };
        MouseLeftButtonUp += delegate { if (Click != null) Click(); };
    }

    public void Select(bool on)
    {
        selected = on;
        Pal.Tint(fill, on ? Pal.Hover : "#00000000", 200);
        Pal.Tint(fg, on ? Pal.Fg : Pal.Fg2, 200);
    }
}

/// Question that slides open on click.
class Faq : StackPanel
{
    readonly Border body;
    readonly TextBlock sign = Pal.Text("+", 16, Pal.Fg2, false);
    double full;
    bool open;

    public Faq(string question, string answer)
    {
        Grid head = new Grid { Margin = new Thickness(18, 15, 18, 15), Background = Pal.B("#00000000"), Cursor = Cursors.Hand };
        head.ColumnDefinitions.Add(new ColumnDefinition());
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        TextBlock q = Pal.Text(question, 14, Pal.Fg, false);
        q.FontWeight = FontWeights.Medium;
        Grid.SetColumn(sign, 1);
        head.Children.Add(q); head.Children.Add(sign);
        TextBlock a = Pal.Text(answer, 13.5, Pal.Fg2, false);
        a.LineHeight = 21;
        a.Margin = new Thickness(18, 0, 18, 16);
        a.MaxWidth = 640; a.HorizontalAlignment = HorizontalAlignment.Left;
        body = new Border { Child = a, Height = 0, ClipToBounds = true };
        Children.Add(head); Children.Add(body);
        head.MouseLeftButtonUp += delegate
        {
            open = !open;
            sign.Text = open ? "–" : "+";
            if (full == 0) { a.Measure(new Size(700, double.PositiveInfinity)); full = a.DesiredSize.Height + 16; }
            body.BeginAnimation(FrameworkElement.HeightProperty, new DoubleAnimation(open ? full : 0, TimeSpan.FromMilliseconds(220)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        };
    }
}

/// Things the window reads straight from Windows, so they show even when the bridge isn't answering.
static class Local
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "SimPilot Bridge";

    /// The PC's LAN addresses as "ip:port", Wi-Fi/Ethernet first and VPN/virtual adapters last.
    public static List<string> Addresses()
    {
        List<KeyValuePair<int, string>> found = new List<KeyValuePair<int, string>>();
        try
        {
            foreach (NetworkInterface nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                int rank = Regex.IsMatch(nic.Name + " " + nic.Description, "vpn|virtual|vethernet|vmware|wsl|tun|docker|hyper-v|tap|bluetooth", RegexOptions.IgnoreCase) ? 1 : 0;
                foreach (UnicastIPAddressInformation ip in nic.GetIPProperties().UnicastAddresses)
                    if (ip.Address.AddressFamily == AddressFamily.InterNetwork && !ip.Address.ToString().StartsWith("169.254."))
                        found.Add(new KeyValuePair<int, string>(rank, ip.Address + ":" + Program.Port));
            }
        }
        catch (Exception) { }
        List<string> result = new List<string>();
        foreach (KeyValuePair<int, string> f in found) if (f.Key == 0) result.Add(f.Value);
        foreach (KeyValuePair<int, string> f in found) if (f.Key != 0) result.Add(f.Value);
        return result;
    }

    public static bool AutostartOn()
    {
        try { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(RunName) != null; }
        catch (Exception) { return false; }
    }

    public static bool SetAutostart(bool on)
    {
        try
        {
            using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue(RunName, "\"" + System.Windows.Forms.Application.ExecutablePath + "\" --minimized");
                else k.DeleteValue(RunName, false);
            }
            return true;
        }
        catch (Exception) { return false; }
    }

    /// MSFS 2024's Community2024 folder from UserCfg.opt (Microsoft Store and Steam keep it in different places).
    public static string FindCommunity(out bool installed)
    {
        installed = false;
        List<string> configs = new List<string>();
        string local = Environment.GetEnvironmentVariable("LOCALAPPDATA"), roaming = Environment.GetEnvironmentVariable("APPDATA");
        try
        {
            string packages = Path.Combine(local ?? "", "Packages");
            if (local != null && Directory.Exists(packages))
                foreach (string d in Directory.GetDirectories(packages, "Microsoft.Limitless_*"))
                {
                    configs.Add(Path.Combine(d, @"LocalCache\UserCfg.opt"));
                    configs.Add(Path.Combine(d, @"LocalState\UserCfg.opt"));
                }
        }
        catch (Exception) { }
        if (roaming != null) configs.Add(Path.Combine(roaming, @"Microsoft Flight Simulator 2024\UserCfg.opt"));
        string fallback = null;
        foreach (string cfg in configs)
        {
            string packagesPath = null;
            try
            {
                if (!File.Exists(cfg)) continue;
                foreach (string line in File.ReadAllLines(cfg))
                {
                    Match m = Regex.Match(line, "^\\s*InstalledPackagesPath\\s+\"([^\"]+)\"");
                    if (m.Success) { packagesPath = m.Groups[1].Value.Trim(); break; }
                }
            }
            catch (Exception) { }
            if (packagesPath == null || !Directory.Exists(packagesPath)) continue;
            foreach (string name in new[] { "Community2024", "Community" })
            {
                string c = Path.Combine(packagesPath, name);
                if (Directory.Exists(Path.Combine(c, "simpilot-link"))) { installed = true; return c; }
            }
            if (fallback == null) fallback = Path.Combine(packagesPath, "Community2024");
        }
        return fallback;
    }

    /// Same rules as build.ps1 for a folder the user picked: Packages, Community2024 or simpilot-link itself.
    public static string CommunityFromChoice(string selected, out bool installed)
    {
        selected = selected.TrimEnd('\\', '/');
        string leaf = Path.GetFileName(selected);
        string community = leaf.Equals("Community2024", StringComparison.OrdinalIgnoreCase) || leaf.Equals("Community", StringComparison.OrdinalIgnoreCase) ? selected
            : leaf.Equals("simpilot-link", StringComparison.OrdinalIgnoreCase) ? Path.GetDirectoryName(selected) : Path.Combine(selected, "Community2024");
        installed = Directory.Exists(Path.Combine(community, "simpilot-link"));
        return community;
    }

    public static string SdkPath()
    {
        string[] candidates = {
            Environment.GetEnvironmentVariable("MSFS2024_SDK"),
            Environment.GetEnvironmentVariable("MSFS2024_SDK", EnvironmentVariableTarget.User),
            Environment.GetEnvironmentVariable("MSFS2024_SDK", EnvironmentVariableTarget.Machine),
            @"C:\MSFS 2024 SDK",
            Path.Combine(Environment.GetEnvironmentVariable("SystemDrive") ?? "C:", "MSFS 2024 SDK") };
        foreach (string c in candidates)
        {
            try { if (!string.IsNullOrEmpty(c) && File.Exists(Path.Combine(c, @"Tools\bin\fspackagetool.exe"))) return c; } catch (Exception) { }
        }
        return null;
    }

    public static bool SimRunning()
    {
        try { return Process.GetProcessesByName("FlightSimulator2024").Length > 0; } catch (Exception) { return false; }
    }
}

/// One line of the install checklist: a numbered badge that turns into a tick, a title, a detail line and an optional button.
class StepRow : Grid
{
    readonly SolidColorBrush badgeFill = Pal.B(Pal.Hover2);
    readonly TextBlock number;
    readonly Shapes.Path tick = new Shapes.Path { Data = Geometry.Parse("M4,9 L7.5,12.5 L14,5.5"), Stroke = Pal.B(Pal.Fg), StrokeThickness = 2, Width = 18, Height = 18, Opacity = 0, StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, RenderTransformOrigin = new Point(0.5, 0.5) };
    readonly ScaleTransform pop = new ScaleTransform(0.4, 0.4);
    readonly TextBlock detail;
    readonly ContentControl slot = new ContentControl { VerticalAlignment = VerticalAlignment.Center };
    string state = "todo";

    public StepRow(int n, string title)
    {
        Margin = new Thickness(0, 0, 0, 18);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Border badge = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(14), Background = badgeFill, Margin = new Thickness(0, 0, 14, 0), VerticalAlignment = VerticalAlignment.Top };
        Grid inner = new Grid();
        number = Pal.Text(n.ToString(), 13, Pal.Fg2, true); number.HorizontalAlignment = HorizontalAlignment.Center;
        tick.RenderTransform = pop;
        inner.Children.Add(number); inner.Children.Add(tick);
        badge.Child = inner;
        StackPanel text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        TextBlock t = Pal.Text(title, 14.5, Pal.Fg, false); t.FontWeight = FontWeights.Medium;
        detail = Pal.Text("", 13, Pal.Fg2, false); detail.Margin = new Thickness(0, 3, 0, 0); detail.LineHeight = 19;
        text.Children.Add(t); text.Children.Add(detail);
        Grid.SetColumn(text, 1); Grid.SetColumn(slot, 2);
        slot.Margin = new Thickness(16, 0, 0, 0);
        Children.Add(badge); Children.Add(text); Children.Add(slot);
    }

    public void Set(string newState, string text, UIElement action)
    {
        detail.Text = text;
        slot.Content = action;
        if (newState == state) return;
        state = newState;
        Pal.Tint(badgeFill, newState == "done" ? Pal.Ok : newState == "fail" ? "#8A3A3F" : newState == "active" ? Pal.Blue : Pal.Hover2, 260);
        ((SolidColorBrush)number.Foreground).Color = Pal.C(newState == "todo" ? Pal.Fg2 : Pal.Fg);
        bool done = newState == "done";
        Pal.Fade(number, done ? 0 : 1, 160);
        Pal.Fade(tick, done ? 1 : 0, 200);
        if (done)
        {
            DoubleAnimation grow = new DoubleAnimation(0.4, 1, TimeSpan.FromMilliseconds(380)) { EasingFunction = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.6 } };
            pop.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
            pop.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        }
    }
}

/// Guided chart panel install: finds MSFS 2024, checks the SDK and that the sim is closed, then runs build.ps1 with live progress.
class PanelWizard : Grid
{
    readonly MainWindow owner;
    readonly string panelDir;
    readonly Border card;
    readonly TranslateTransform cardMove = new TranslateTransform(0, 24);
    readonly TextBlock title, subtitle, next;
    readonly StepRow sFind, sSdk, sSim, sInstall;
    readonly Border barTrack, barFill, shimmer;
    readonly TranslateTransform shimmerMove = new TranslateTransform(-120, 0);
    readonly TextBlock barText;
    readonly TextBlock logText;
    readonly ScrollViewer logScroll;
    readonly Btn details, cancel, go;
    readonly DispatcherTimer simTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
    readonly StringBuilder log = new StringBuilder();
    string community;
    bool installed, sdkOk, simClosed, running, finished, logOpen;
    double progress;

    public PanelWizard(MainWindow owner, string appDir)
    {
        this.owner = owner;
        panelDir = Path.Combine(appDir, "Chart panel (optional)");
        Visibility = Visibility.Collapsed;
        Background = new SolidColorBrush(Color.FromArgb(0xB0, 0x10, 0x12, 0x15));
        card = new Border { Width = 600, Background = Pal.B(Pal.Panel), BorderBrush = Pal.B(Pal.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14), Padding = new Thickness(32, 28, 32, 24), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, RenderTransform = cardMove };
        StackPanel s = new StackPanel();
        title = Pal.Text("Install the chart panel", 22, Pal.Fg, true);
        subtitle = Pal.Text("SimPilot Link sends the sim's own charts to your iPad. Setting it up takes about two minutes.", 14, Pal.Fg2, false);
        subtitle.Margin = new Thickness(0, 6, 0, 26);
        s.Children.Add(title); s.Children.Add(subtitle);
        sFind = new StepRow(1, "Find MSFS 2024"); sSdk = new StepRow(2, "MSFS 2024 SDK"); sSim = new StepRow(3, "Close MSFS 2024"); sInstall = new StepRow(4, "Install SimPilot Link");
        s.Children.Add(sFind); s.Children.Add(sSdk); s.Children.Add(sSim); s.Children.Add(sInstall);

        barTrack = new Border { Height = 6, CornerRadius = new CornerRadius(3), Background = Pal.B(Pal.Hover2), Margin = new Thickness(42, -6, 0, 0), ClipToBounds = true, Opacity = 0 };
        Grid barInner = new Grid();
        barFill = new Border { CornerRadius = new CornerRadius(3), Background = Pal.B(Pal.Blue), HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };
        shimmer = new Border { Width = 120, HorizontalAlignment = HorizontalAlignment.Left, RenderTransform = shimmerMove,
            Background = new LinearGradientBrush(new GradientStopCollection { new GradientStop(Color.FromArgb(0, 255, 255, 255), 0), new GradientStop(Color.FromArgb(70, 255, 255, 255), 0.5), new GradientStop(Color.FromArgb(0, 255, 255, 255), 1) }, 0) };
        barInner.Children.Add(barFill); barInner.Children.Add(shimmer);
        barTrack.Child = barInner;
        barText = Pal.Text("", 12.5, Pal.Fg2, false); barText.Margin = new Thickness(42, 8, 0, 0);
        s.Children.Add(barTrack); s.Children.Add(barText);

        next = Pal.Text("", 14, Pal.Fg, false); next.LineHeight = 22; next.Margin = new Thickness(0, 4, 0, 0); next.Visibility = Visibility.Collapsed;
        s.Children.Add(next);

        logText = new TextBlock { FontFamily = Pal.Mono, FontSize = 11.5, Foreground = Pal.B(Pal.Fg2), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 10, 12, 10) };
        logScroll = new ScrollViewer { Content = logText, Height = 0, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = Pal.B(Pal.Frame), Margin = new Thickness(0, 14, 0, 0) };
        s.Children.Add(logScroll);

        Grid foot = new Grid { Margin = new Thickness(0, 22, 0, 0) };
        details = new Btn("Show details", "ghost") { HorizontalAlignment = HorizontalAlignment.Left };
        details.Click += ToggleDetails;
        StackPanel right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        cancel = new Btn("Cancel", "ghost") { Margin = new Thickness(0, 0, 10, 0) };
        cancel.Click += delegate { Close(); };
        go = new Btn("Install", "primary");
        go.Click += Go;
        right.Children.Add(cancel); right.Children.Add(go);
        foot.Children.Add(details); foot.Children.Add(right);
        s.Children.Add(foot);
        card.Child = s;
        Children.Add(card);
        simTimer.Tick += delegate { CheckSim(); };
    }

    public void Open()
    {
        if (running) { Show(); return; }
        finished = false; progress = 0; log.Length = 0; logText.Text = "";
        title.Text = "Install the chart panel";
        subtitle.Text = "SimPilot Link sends the sim's own charts to your iPad. Setting it up takes about two minutes.";
        next.Visibility = Visibility.Collapsed;
        barTrack.Opacity = 0; barText.Text = ""; barFill.Width = 0;
        cancel.Visibility = Visibility.Visible;
        sInstall.Set("todo", "Copies the panel into the sim's Community folder.", null);
        community = Local.FindCommunity(out installed);
        Evaluate();
        Show();
    }

    void Show()
    {
        Visibility = Visibility.Visible;
        Opacity = 0;
        Pal.Fade(this, 1, 200);
        Pal.Slide(cardMove, TranslateTransform.YProperty, 24, 0, 320);
        simTimer.Start();
    }

    void Close()
    {
        if (running) return;
        simTimer.Stop();
        DoubleAnimation fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(180));
        fade.Completed += delegate { Visibility = Visibility.Collapsed; };
        BeginAnimation(OpacityProperty, fade);
        Pal.Slide(cardMove, TranslateTransform.YProperty, 0, 16, 180);
    }

    Btn Small(string text, Action click) { Btn b = new Btn(text, "ghost"); b.Padding = new Thickness(12, 5, 12, 5); b.Click += click; return b; }

    void Evaluate()
    {
        if (community == null)
            sFind.Set("fail", "Couldn't find where MSFS 2024 keeps its add-ons. Choose the Packages folder (the one with Community2024 in it).", Small("Choose folder", Choose));
        else
            sFind.Set("done", (installed ? "SimPilot Link is already installed in " : "Will install into ") + community, Small("Change", Choose));

        string sdk = Local.SdkPath();
        sdkOk = sdk != null;
        if (installed) sSdk.Set("done", "Not needed: the panel is already installed, so it is updated in place.", null);
        else if (sdkOk) sSdk.Set("done", "Found in " + sdk + ". It is only needed this once.", null);
        else sSdk.Set("fail", "Needed once to add the panel. In MSFS 2024 open Settings > Advanced Options > Developer Mode and switch it on, then choose Help > SDK Installer in the menu bar at the top and install it.", Small("Check again", delegate { Evaluate(); }));
        go.Text = installed ? "Update panel" : "Install";
        CheckSim();
    }

    void CheckSim()
    {
        if (running || finished) return;
        simClosed = !Local.SimRunning();
        sSim.Set(simClosed ? "done" : "active", simClosed ? "MSFS 2024 is closed." : "MSFS 2024 is open. Close it to continue; this updates by itself.", null);
        go.IsEnabled = community != null && (installed || sdkOk) && simClosed && File.Exists(Path.Combine(panelDir, "build.ps1"));
        if (!File.Exists(Path.Combine(panelDir, "build.ps1"))) sInstall.Set("fail", "The \"Chart panel (optional)\" folder is missing next to SimPilot Bridge.exe. Extract the whole SimPilot-for-PC.zip and run it from there.", null);
    }

    void Choose()
    {
        Forms.FolderBrowserDialog dialog = new Forms.FolderBrowserDialog { Description = "Select the MSFS 2024 Packages folder, or Community2024 if it already exists.", ShowNewFolderButton = false };
        if (dialog.ShowDialog() != Forms.DialogResult.OK || string.IsNullOrEmpty(dialog.SelectedPath)) return;
        community = Local.CommunityFromChoice(dialog.SelectedPath, out installed);
        Evaluate();
    }

    void ToggleDetails()
    {
        logOpen = !logOpen;
        details.Text = logOpen ? "Hide details" : "Show details";
        logScroll.BeginAnimation(FrameworkElement.HeightProperty, new DoubleAnimation(logOpen ? 180 : 0, TimeSpan.FromMilliseconds(240)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
    }

    void SetProgress(double value, string text)
    {
        progress = Math.Max(progress, value);
        barText.Text = text;
        double width = Math.Max(0, barTrack.ActualWidth > 0 ? barTrack.ActualWidth : 516) * progress;
        barFill.BeginAnimation(FrameworkElement.WidthProperty, new DoubleAnimation(width, TimeSpan.FromMilliseconds(500)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
    }

    void Go()
    {
        if (finished) { Close(); return; }
        if (running || !go.IsEnabled) return;
        running = true; progress = 0; log.Length = 0; logText.Text = "";
        go.IsEnabled = false; cancel.Visibility = Visibility.Collapsed;
        ((SolidColorBrush)barFill.Background).Color = Pal.C(Pal.Blue);
        sInstall.Set("active", installed ? "Updating the panel files..." : "Building and installing. The SDK may take a minute.", null);
        barTrack.Opacity = 0; Pal.Fade(barTrack, 1, 200);
        shimmerMove.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-120, 600, TimeSpan.FromMilliseconds(1300)) { RepeatBehavior = RepeatBehavior.Forever });
        SetProgress(0.05, "Starting...");
        string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(panelDir, "build.ps1") + "\" -Community \"" + community.TrimEnd('\\') + "\"" + (installed ? " -UpdateScript" : "");
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, WorkingDirectory = panelDir };
        try
        {
            Process ps = new Process { StartInfo = psi, EnableRaisingEvents = true };
            ps.OutputDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null) Dispatcher.BeginInvoke(new Action(delegate { Line(e.Data); })); };
            ps.ErrorDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null) Dispatcher.BeginInvoke(new Action(delegate { Line(e.Data); })); };
            ps.Exited += delegate { int code = 1; try { code = ps.ExitCode; } catch (Exception) { } Dispatcher.BeginInvoke(new Action(delegate { Done(code); })); };
            ps.Start();
            ps.StandardInput.Close();   // nothing may wait for typed input
            ps.BeginOutputReadLine();
            ps.BeginErrorReadLine();
        }
        catch (Exception ex) { Line("Couldn't start PowerShell: " + ex.Message); Done(1); }
    }

    void Line(string text)
    {
        log.AppendLine(text);
        logText.Text = log.ToString();
        logScroll.ScrollToEnd();
        Match m = Regex.Match(text, "^== (\\d)/4 (.+)$");
        if (m.Success) SetProgress(int.Parse(m.Groups[1].Value) / 4.0 - 0.1, m.Groups[2].Value);
    }

    void Done(int code)
    {
        if (!running) return;
        running = false;
        shimmerMove.BeginAnimation(TranslateTransform.XProperty, null);
        shimmerMove.X = -120;
        if (code == 0)
        {
            finished = true;
            SetProgress(1, "Finished");
            sInstall.Set("done", "Installed in " + community + ".", null);
            title.Text = installed ? "Chart panel updated" : "Chart panel installed";
            subtitle.Text = "One last thing in the sim:";
            next.Text = "1.  Start MSFS 2024 (new panels load only when the sim starts) and load into a flight.\n2.  Click the gear icon in the toolbar, switch SimPilot Link on and open it.\n3.  Leave the panel open while you fly. The Status page then shows the chart panel as connected.";
            next.Visibility = Visibility.Visible; next.Opacity = 0; Pal.Fade(next, 1, 300);
            go.Text = "Done"; go.IsEnabled = true;
            owner.Toast(installed ? "Chart panel updated." : "Chart panel installed.");
            installed = true;
            return;
        }
        string last = "";
        foreach (string l in log.ToString().Split('\n')) { string t = l.Trim(); if (t.Length > 0 && !t.StartsWith("==") && !t.StartsWith("At ") && !t.StartsWith("+ ")) last = t; }
        sInstall.Set("fail", last.Length > 0 ? last : "The installer stopped (exit code " + code + ").", null);
        ((SolidColorBrush)barFill.Background).Color = Pal.C(Pal.Bad);
        barText.Text = "Didn't finish";
        if (!logOpen) ToggleDetails();
        go.Text = "Try again"; cancel.Visibility = Visibility.Visible;
        Evaluate();
    }
}

class MainWindow : Window
{
    readonly TrayApp host;
    PanelWizard wizard;
    readonly Grid pages = new Grid();
    readonly List<FrameworkElement> pageList = new List<FrameworkElement>();
    readonly List<NavItem> navItems = new List<NavItem>();
    readonly Dictionary<string, Btn> actions = new Dictionary<string, Btn>();
    readonly DispatcherTimer timer = new DispatcherTimer();
    readonly TextBlock toast = Pal.Text("", 13.5, Pal.Fg2, false);

    TextBlock hostText, topIp, connText, version, newVersion, lede, addr, cacheSize, logText;
    Dot connDot, dIpad, dSim, dLink;
    TextBlock tIpad, tSim, tLink;
    StackPanel airports;
    ScrollViewer logScroll;
    Switch autostart;
    Btn install, restart;
    Shapes.Path eyeOpen, eyeShut;
    bool ipHidden, polling, infoLoading, logLoading, updateBusy;
    int current = -1, misses, tick;
    string firstAddress = "";
    string lastLog = "";
    DispatcherTimer toastTimer = new DispatcherTimer();

    public MainWindow(TrayApp host)
    {
        this.host = host;
        Title = "SimPilot Bridge";
        Width = 1040; Height = 680;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Pal.B(Pal.Frame);
        BorderBrush = Pal.B(Pal.Line);
        BorderThickness = new Thickness(1);
        UseLayoutRounding = true;
        TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        FontFamily = Pal.Sans;
        try { Icon = BitmapFrame.Create(LogoStream(), BitmapCreateOptions.None, BitmapCacheOption.OnLoad); } catch (Exception) { }

        Grid root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(52) });
        root.RowDefinitions.Add(new RowDefinition());
        Grid top = TopBar();
        root.Children.Add(top);
        Grid body = new Grid { Margin = new Thickness(10, 0, 10, 10) };
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        body.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        Grid side = Sidebar();
        body.Children.Add(side);
        Border panel = new Border { Background = Pal.B(Pal.Panel), BorderBrush = Pal.B(Pal.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Margin = new Thickness(8, 0, 0, 0), ClipToBounds = true };
        Grid.SetColumn(panel, 1);
        Grid content = new Grid();
        content.RowDefinitions.Add(new RowDefinition());
        content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        content.Children.Add(pages);
        toast.Margin = new Thickness(30, 0, 30, 14); toast.Opacity = 0;
        Grid.SetRow(toast, 1);
        content.Children.Add(toast);
        panel.Child = content;
        body.Children.Add(panel);
        Content = root;

        AddPage(StatusPage()); AddPage(ChartsPage()); AddPage(LogPage()); AddPage(RepairPage()); AddPage(HelpPage());
        wizard = new PanelWizard(this, AppDomain.CurrentDomain.BaseDirectory);
        Grid.SetRowSpan(wizard, 2);
        root.Children.Add(wizard);
        hostText.Text = Environment.MachineName;
        UpdateAddresses();
        autostart.Set(Local.AutostartOn(), false);
        top.MouseLeftButtonDown += delegate { try { DragMove(); } catch (Exception) { } };

        // opening: fade up and settle
        Opacity = 0;
        ScaleTransform grow = new ScaleTransform(0.975, 0.975);
        root.RenderTransform = grow; root.RenderTransformOrigin = new Point(0.5, 0.5);
        Loaded += delegate
        {
            Pal.Fade(this, 1, 260);
            grow.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(320)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            grow.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(320)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
        };
        ShowPage(0);

        toastTimer.Interval = TimeSpan.FromSeconds(5);
        toastTimer.Tick += delegate { toastTimer.Stop(); Pal.Fade(toast, 0, 300); };
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.Tick += delegate { Refresh(); };
        if (host != null) { timer.Start(); Refresh(); CheckUpdate(); }
        IsVisibleChanged += delegate { if (IsVisible && host != null) Refresh(); };
    }

    public static Stream LogoStream() { return Assembly.GetExecutingAssembly().GetManifestResourceStream("logo.png"); }

    static BitmapImage Logo()
    {
        BitmapImage img = new BitmapImage();
        img.BeginInit(); img.StreamSource = LogoStream(); img.CacheOption = BitmapCacheOption.OnLoad; img.EndInit(); img.Freeze();
        return img;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        if (host != null) { e.Cancel = true; Hide(); host.WindowHidden(); return; }
        base.OnClosing(e);
    }

    // ---- layout ----

    Grid TopBar()
    {
        Grid g = new Grid { Background = Pal.B("#00000000") };
        StackPanel left = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new Image { Source = Logo(), Width = 24, Height = 24, Margin = new Thickness(0, 0, 9, 0), IsHitTestVisible = false });
        TextBlock name = Pal.Text("SimPilot Bridge", 14, Pal.Fg, true); name.IsHitTestVisible = false;
        left.Children.Add(name);
        Border pill = new Border { BorderBrush = Pal.B(Pal.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(16, 0, 0, 0), IsHitTestVisible = false };
        StackPanel pp = new StackPanel { Orientation = Orientation.Horizontal };
        hostText = Pal.Text("", 13.5, Pal.Fg, false); hostText.FontWeight = FontWeights.Medium;
        topIp = Pal.Text("", 12.5, Pal.Fg2, false); topIp.Margin = new Thickness(8, 0, 0, 0);
        pp.Children.Add(hostText); pp.Children.Add(topIp);
        pill.Child = pp;
        left.Children.Add(pill);
        g.Children.Add(left);

        StackPanel right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        connDot = new Dot { VerticalAlignment = VerticalAlignment.Center };
        connText = Pal.Text("Starting", 13, Pal.Fg2, false); connText.Margin = new Thickness(6, 0, 18, 0);
        right.Children.Add(connDot); right.Children.Add(connText);
        right.Children.Add(CaptionButton("–", false)); right.Children.Add(CaptionButton("✕", true));
        g.Children.Add(right);
        return g;
    }

    Border CaptionButton(string glyph, bool close)
    {
        SolidColorBrush fill = Pal.B("#00000000");
        TextBlock t = Pal.Text(glyph, 12, Pal.Fg2, false); t.HorizontalAlignment = HorizontalAlignment.Center;
        Border b = new Border { Width = 46, Height = 52, Background = fill, Child = t, Cursor = Cursors.Hand };
        b.MouseEnter += delegate { Pal.Tint(fill, close ? "#C42B1C" : Pal.Hover2, 120); ((SolidColorBrush)t.Foreground).Color = Pal.C(Pal.Fg); };
        b.MouseLeave += delegate { Pal.Tint(fill, "#00000000", 160); ((SolidColorBrush)t.Foreground).Color = Pal.C(Pal.Fg2); };
        b.MouseLeftButtonDown += delegate (object s, MouseButtonEventArgs e) { e.Handled = true; };
        b.MouseLeftButtonUp += delegate { if (close) Close(); else WindowState = WindowState.Minimized; };
        return b;
    }

    Grid Sidebar()
    {
        Grid shell = new Grid { Margin = new Thickness(0, 4, 0, 0) };
        shell.RowDefinitions.Add(new RowDefinition());
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        StackPanel nav = new StackPanel();
        string[] names = { "Status", "Charts", "Log", "Repair", "Help" };
        string[] icons = {
            "M2,2H7V7H2Z M9,2H14V7H9Z M2,9H7V14H2Z M9,9H14V14H9Z",
            "M3,2H13V14H3Z M6,6H10 M6,9H10",
            "M3,4H13 M3,8H13 M3,12H9",
            "M10.5,2.5 A3,3 0 0 0 6.8,6.4 L2.5,10.7 L5.3,13.5 L9.6,9.2 A3,3 0 0 0 13.5,5.5 L11.7,7.3 L9.7,6.8 L9.2,4.8 Z",
            "M2,8 A6,6 0 1 0 14,8 A6,6 0 1 0 2,8 Z M6.3,6.3 A1.8,1.8 0 1 1 8.7,8 C8.2,8.2 8,8.6 8,9.1 M8,11.2 L8,11.3" };
        for (int i = 0; i < names.Length; i++)
        {
            int index = i;
            NavItem n = new NavItem(names[i], icons[i]) { Margin = new Thickness(0, 0, 0, 2) };
            n.Click += delegate { ShowPage(index); };
            navItems.Add(n); nav.Children.Add(n);
        }
        shell.Children.Add(nav);
        Grid me = new Grid { Margin = new Thickness(12, 0, 0, 12) };
        me.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        me.ColumnDefinitions.Add(new ColumnDefinition());
        Image logo = new Image { Source = Logo(), Width = 30, Height = 30, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        StackPanel tx = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        version = Pal.Text("Version", 13.5, Pal.Fg, false);
        newVersion = Pal.Text("", 12, Pal.Fg2, false);
        tx.Children.Add(version); tx.Children.Add(newVersion);
        Grid.SetColumn(tx, 1);
        me.Children.Add(logo); me.Children.Add(tx);
        Grid.SetRow(me, 1);
        shell.Children.Add(me);
        return shell;
    }

    static StackPanel Page()
    {
        return new StackPanel { Margin = new Thickness(30, 26, 30, 20) };
    }

    static Grid Header(string title, params UIElement[] buttons)
    {
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition());
        TextBlock t = Pal.Text(title, 21, Pal.Fg, true);
        g.Children.Add(t);
        StackPanel row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (UIElement b in buttons) { ((FrameworkElement)b).Margin = new Thickness(10, 0, 0, 0); row.Children.Add(b); }
        g.Children.Add(row);
        return g;
    }

    static TextBlock Lede(string text) { TextBlock t = Pal.Text(text, 14, Pal.Fg2, false); t.Margin = new Thickness(0, 16, 0, 24); return t; }

    static Border Box(UIElement child)
    {
        return new Border { BorderBrush = Pal.B(Pal.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Child = child, ClipToBounds = true };
    }

    static Border Divider() { return new Border { Height = 1, Background = Pal.B(Pal.Line) }; }

    static TextBlock Heading(string text) { TextBlock t = Pal.Text(text, 13, Pal.Fg2, false); t.FontWeight = FontWeights.Medium; t.Margin = new Thickness(0, 26, 0, 10); return t; }

    Grid StatusRow(out Dot dot, out TextBlock sub, string title)
    {
        Grid g = new Grid { Margin = new Thickness(18, 15, 18, 15) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        dot = new Dot { Margin = new Thickness(-5, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center };
        StackPanel s = new StackPanel();
        TextBlock t = Pal.Text(title, 14, Pal.Fg, false); t.FontWeight = FontWeights.Medium;
        sub = Pal.Text("", 13, Pal.Fg2, false);
        s.Children.Add(t); s.Children.Add(sub);
        Grid.SetColumn(s, 1);
        g.Children.Add(dot); g.Children.Add(s);
        return g;
    }

    FrameworkElement StatusPage()
    {
        StackPanel p = Page();
        Btn log = new Btn("Open log", "ghost"); log.Click += delegate { ShowPage(2); };
        install = new Btn("Install update", "primary"); install.Visibility = Visibility.Collapsed; install.Click += InstallUpdate;
        restart = new Btn("Restart bridge", "ghost"); restart.Visibility = Visibility.Collapsed; restart.Click += delegate { if (host != null) host.RestartBridge(); };
        p.Children.Add(Header("Status", restart, log, install));
        lede = Lede("Starting the bridge..."); p.Children.Add(lede);
        StackPanel rows = new StackPanel();
        rows.Children.Add(StatusRow(out dIpad, out tIpad, "iPad")); rows.Children.Add(Divider());
        rows.Children.Add(StatusRow(out dSim, out tSim, "MSFS 2024")); rows.Children.Add(Divider());
        rows.Children.Add(StatusRow(out dLink, out tLink, "Chart panel"));
        p.Children.Add(Box(rows));

        StackPanel line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 22, 0, 0) };
        line.Children.Add(Pal.Text("If the iPad doesn't find this PC, enter", 13.5, Pal.Fg2, false));
        Border code = new Border { Background = Pal.B(Pal.Hover), BorderBrush = Pal.B(Pal.Line), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(7), Padding = new Thickness(10, 5, 10, 5), Margin = new Thickness(12, 0, 8, 0) };
        addr = Pal.Text("", 13.5, Pal.Fg, false); addr.FontFamily = Pal.Mono; addr.TextWrapping = TextWrapping.NoWrap;
        code.Child = addr; line.Children.Add(code);
        eyeOpen = Pal.Icon("M1.5,8 C1.5,8 4,3.5 8,3.5 C12,3.5 14.5,8 14.5,8 C14.5,8 12,12.5 8,12.5 C4,12.5 1.5,8 1.5,8 Z M10,8 A2,2 0 1 0 6,8 A2,2 0 1 0 10,8 Z", Pal.Fg2);
        eyeShut = Pal.Icon("M1.5,8 C1.5,8 4,3.5 8,3.5 C12,3.5 14.5,8 14.5,8 C14.5,8 12,12.5 8,12.5 C4,12.5 1.5,8 1.5,8 Z M10,8 A2,2 0 1 0 6,8 A2,2 0 1 0 10,8 Z M2,2 L14,14", Pal.Fg2);
        eyeShut.Opacity = 0;
        Grid eyeIcon = new Grid { Width = 16, Height = 16 }; eyeIcon.Children.Add(eyeOpen); eyeIcon.Children.Add(eyeShut);
        Btn eye = new Btn("", "icon"); eye.Padding = new Thickness(7); eye.SetContent(eyeIcon); eye.ToolTip = "Hide or show the address";
        eye.Click += delegate
        {
            ipHidden = !ipHidden;
            Pal.Fade(eyeOpen, ipHidden ? 0 : 1, 160); Pal.Fade(eyeShut, ipHidden ? 1 : 0, 160);
            RenderAddress();
        };
        line.Children.Add(eye);
        p.Children.Add(line);

        p.Children.Add(new Border { Height = 1, Background = Pal.B(Pal.Line), Margin = new Thickness(0, 28, 0, 18) });
        StackPanel auto = new StackPanel { Orientation = Orientation.Horizontal };
        autostart = new Switch();
        autostart.Changed += delegate
        {
            if (Local.SetAutostart(autostart.On)) Toast(autostart.On ? "SimPilot Bridge will start with Windows, hidden in the tray." : "Start with Windows is off.");
            else { autostart.Set(!autostart.On, true); Toast("Couldn't change Start with Windows."); }
        };
        TextBlock lbl = Pal.Text("Start with Windows, hidden in the tray", 13.5, Pal.Fg2, false); lbl.Margin = new Thickness(10, 0, 0, 0);
        auto.Children.Add(autostart); auto.Children.Add(lbl);
        p.Children.Add(auto);
        return Scroll(p);
    }

    FrameworkElement ChartsPage()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Charts", ActionButton("open-cache", "Open cache folder", "ghost", false), WizardButton("Install chart panel", "primary")));
        p.Children.Add(Lede("Charts exported from the sim's Lido charts. The iPad asks for them when you open an airport."));
        airports = new StackPanel();
        p.Children.Add(Box(airports));
        cacheSize = Pal.Text("", 13.5, Pal.Fg2, false); cacheSize.Margin = new Thickness(0, 22, 0, 0);
        p.Children.Add(cacheSize);
        return Scroll(p);
    }

    FrameworkElement LogPage()
    {
        StackPanel p = Page();
        Btn copy = new Btn("Copy", "ghost");
        copy.Click += delegate
        {
            try { Clipboard.SetText(logText.Text.Length == 0 ? " " : logText.Text); Toast("Log copied."); } catch (Exception) { Toast("Couldn't reach the clipboard."); }
        };
        p.Children.Add(Header("Log", copy));
        p.Children.Add(Lede("What the bridge has been doing. Attach this when reporting a problem."));
        logText = new TextBlock { FontFamily = Pal.Mono, FontSize = 12.5, Foreground = Pal.B(Pal.Fg2), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(16, 12, 16, 12), LineHeight = 22 };
        logScroll = new ScrollViewer { Content = logText, Height = 400, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = Pal.B(Pal.Frame) };
        p.Children.Add(Box(logScroll));
        return Scroll(p);
    }

    Grid ActionRow(string id, string title, string text, string button, bool danger)
    {
        Grid g = new Grid { Margin = new Thickness(18, 15, 18, 15) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        StackPanel s = new StackPanel { Margin = new Thickness(0, 0, 20, 0) };
        TextBlock t = Pal.Text(title, 14, Pal.Fg, false); t.FontWeight = FontWeights.Medium;
        s.Children.Add(t); s.Children.Add(Pal.Text(text, 13, Pal.Fg2, false));
        Btn b = ActionButton(id, button, danger ? "danger" : "ghost", danger);
        b.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(b, 1);
        g.Children.Add(s); g.Children.Add(b);
        return g;
    }

    FrameworkElement RepairPage()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Repair"));
        p.Children.Add(Lede("Fix common problems. None of these touch your flights or the iPad app."));
        p.Children.Add(Heading("Repair"));
        StackPanel fix = new StackPanel();
        fix.Children.Add(ActionRow("firewall", "Allow through Windows Firewall", "Adds the rule for private networks if the iPad can't connect. Windows asks for admin approval.", "Fix firewall", false)); fix.Children.Add(Divider());
        fix.Children.Add(WizardRow("Install or repair chart panel", "Guides you through installing SimPilot Link in MSFS 2024, or puts its files back if it stopped working.")); fix.Children.Add(Divider());
        fix.Children.Add(ActionRow("clear-cache", "Clear chart cache", "Deletes exported charts. They export again when needed.", "Clear cache", false));
        p.Children.Add(Box(fix));
        p.Children.Add(Heading("Uninstall"));
        p.Children.Add(Box(ActionRow("uninstall", "Uninstall SimPilot Bridge", "Removes autostart, the firewall rule and cached charts, then closes. Delete the SimPilot for PC folder to finish. Remove the chart panel by deleting simpilot-link from the sim's Community folder.", "Uninstall", true)));
        return Scroll(p);
    }

    FrameworkElement HelpPage()
    {
        StackPanel p = Page();
        p.Children.Add(Header("Help"));
        p.Children.Add(Lede("Answers to the questions people ask most."));
        string[][] faq = {
            new[] { "The iPad doesn't find the PC", "Check both are on the same Wi-Fi, not a guest network. On the iPad: Settings > Privacy > Local Network > SimPilot EFB on. Otherwise type the address from the Status page into the app under Settings > Bridge." },
            new[] { "Windows Firewall asked something", "Tick \"Private networks\" and click Allow. Windows may call it \"Node.js JavaScript Runtime\"; that is SimPilot Bridge. Missed it? Use Repair > Fix firewall." },
            new[] { "MSFS says waiting", "Start MSFS 2024 and load into a flight. The bridge connects by itself; no setting is needed." },
            new[] { "Do I need the chart panel?", "No. Weather, SimBrief and VATSIM work without it. The panel only sends the sim's own charts to the iPad." },
            new[] { "Charts stay on exporting", "Keep the SimPilot Link panel open in the sim's toolbar and the sim window visible. Exports retry up to three times." },
            new[] { "Does it slow down the sim?", "Barely. It reads position 10 times a second over SimConnect and does nothing else unless the iPad asks." },
            new[] { "How do I update?", "Click Install update when it appears. The bridge downloads the new version and restarts by itself." } };
        StackPanel list = new StackPanel();
        for (int i = 0; i < faq.Length; i++)
        {
            if (i > 0) list.Children.Add(Divider());
            list.Children.Add(new Faq(faq[i][0], faq[i][1]));
        }
        p.Children.Add(Box(list));
        return Scroll(p);
    }

    static ScrollViewer Scroll(UIElement e) { return new ScrollViewer { Content = e, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }; }

    void AddPage(FrameworkElement page)
    {
        page.Visibility = Visibility.Collapsed;
        page.RenderTransform = new TranslateTransform(0, 0);
        pageList.Add(page);
        pages.Children.Add(page);
    }

    public void ShowPage(int index)
    {
        if (index == current) return;
        for (int i = 0; i < pageList.Count; i++)
        {
            navItems[i].Select(i == index);
            if (i != index) { pageList[i].Visibility = Visibility.Collapsed; continue; }
            pageList[i].Visibility = Visibility.Visible;
            pageList[i].Opacity = 0;
            Pal.Fade(pageList[i], 1, 240);
            Pal.Slide((TranslateTransform)pageList[i].RenderTransform, TranslateTransform.YProperty, 14, 0, 280);
        }
        current = index;
        toast.Opacity = 0;
        if (host != null) Refresh();
    }

    // ---- actions ----

    Btn WizardButton(string label, string kind)
    {
        Btn b = new Btn(label, kind);
        b.Click += delegate { OpenWizard(); };
        return b;
    }

    public void OpenWizard() { wizard.Open(); }

    Grid WizardRow(string title, string text)
    {
        Grid g = new Grid { Margin = new Thickness(18, 15, 18, 15) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        StackPanel s = new StackPanel { Margin = new Thickness(0, 0, 20, 0) };
        TextBlock t = Pal.Text(title, 14, Pal.Fg, false); t.FontWeight = FontWeights.Medium;
        s.Children.Add(t); s.Children.Add(Pal.Text(text, 13, Pal.Fg2, false));
        Btn b = WizardButton("Open", "ghost");
        b.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(b, 1);
        g.Children.Add(s); g.Children.Add(b);
        return g;
    }

    void UpdateAddresses()
    {
        List<string> list = Local.Addresses();
        string first = list.Count > 0 ? list[0] : "";
        if (first == firstAddress) return;
        firstAddress = first;
        RenderAddress();
    }

    Btn ActionButton(string id, string label, string kind, bool confirm)
    {
        Btn b = new Btn(label, kind);
        DispatcherTimer disarm = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
        bool armed = false;
        disarm.Tick += delegate { disarm.Stop(); armed = false; b.Text = label; };
        b.Click += delegate
        {
            if (confirm && !armed) { armed = true; b.Text = "Click again to confirm"; disarm.Start(); return; }
            disarm.Stop(); armed = false; b.Text = label;
            Act(id, b, id == "uninstall", null);
        };
        actions[id] = b;
        return b;
    }

    void Act(string id, Btn button, bool quitsAfter, Action<bool> done)
    {
        if (button != null) button.IsEnabled = false;
        if (quitsAfter && host != null) host.DeferQuit = true;
        Toast("Working...");
        ThreadPool.QueueUserWorkItem(delegate
        {
            string message; bool ok = true;
            try { message = Json.Str(Net.Obj("POST", "/bridge/manage/" + id, 180000), "message") ?? "Done."; }
            catch (Exception ex) { message = ex.Message; ok = false; }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                if (button != null) button.IsEnabled = true;
                Toast(message);
                if (done != null) done(ok);
                if (quitsAfter && host != null)
                {
                    if (ok) { MessageBox.Show(this, message, "SimPilot Bridge", MessageBoxButton.OK, MessageBoxImage.Information); host.Quit(); }
                    else host.DeferQuit = false;
                }
                Refresh();
            }));
        });
    }

    public void Toast(string text)
    {
        toast.Text = text;
        Pal.Fade(toast, 1, 160);
        toastTimer.Stop(); toastTimer.Start();
    }

    void InstallUpdate()
    {
        if (updateBusy) return;
        updateBusy = true; install.IsEnabled = false;
        Toast("Downloading the update...");
        ThreadPool.QueueUserWorkItem(delegate
        {
            string error = null;
            try { Net.Call("POST", "/bridge/update", 330000); } catch (Exception ex) { error = ex.Message; }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                updateBusy = false; install.IsEnabled = true;
                if (error == null) Toast("Installing. SimPilot Bridge closes and opens again by itself in a few seconds.");
                else Toast("Update failed: " + error);
            }));
        });
    }

    void CheckUpdate()
    {
        ThreadPool.QueueUserWorkItem(delegate
        {
            object u = null;
            try { u = Net.Obj("GET", "/bridge/update", 25000); } catch (Exception) { }
            if (u == null) return;
            Dispatcher.BeginInvoke(new Action(delegate
            {
                bool available = Json.Bool(u, "available"), can = Json.Bool(u, "canInstall");
                newVersion.Text = available ? Json.Str(u, "latest") + " available" : "Up to date";
                ((SolidColorBrush)newVersion.Foreground).Color = Pal.C(available ? Pal.Warn : Pal.Fg2);
                bool show = available && can;
                if (show && install.Visibility != Visibility.Visible) { install.Visibility = Visibility.Visible; install.Opacity = 0; Pal.Fade(install, 1, 300); }
                if (!show) install.Visibility = Visibility.Collapsed;
            }));
        });
    }

    // ---- live data ----

    void Refresh()
    {
        if (host == null || polling) return;
        polling = true;
        tick++;
        bool wantInfo = (current == 0 || current == 1) && !infoLoading && (current == 1 || tick % 3 == 1);
        bool wantLog = current == 2 && !logLoading;
        if (wantInfo) infoLoading = true;
        if (wantLog) logLoading = true;
        ThreadPool.QueueUserWorkItem(delegate
        {
            object status = null, info = null, log = null;
            try { status = Net.Obj("GET", "/api/status", 1500); } catch (Exception) { }
            if (status != null && wantInfo) { try { info = Net.Obj("GET", "/bridge/info", 4000); } catch (Exception) { } }
            if (status != null && wantLog) { try { log = Net.Obj("GET", "/api/diagnostics", 3000); } catch (Exception) { } }
            Dispatcher.BeginInvoke(new Action(delegate
            {
                polling = false; infoLoading = false; logLoading = false;
                if (tick % 3 == 1) UpdateAddresses();
                bool ours = host.BridgeRunning;
                if (status == null)
                {
                    misses++;
                    if (!ours || misses >= 10) ShowStopped(host.LastError);
                    if (current == 2) ApplyOutput();
                    return;
                }
                misses = 0;
                if (!ours)
                {
                    // Something answers on the port, but not the bridge this program started.
                    ShowStopped("Another SimPilot Bridge is already running on this PC, probably an older copy in a different folder. Close it (look for its window or tray icon), then press Restart bridge.");
                    if (current == 2) ApplyOutput();
                    return;
                }
                ApplyStatus(status);
                if (info != null) ApplyInfo(info);
                if (log != null) ApplyLog(log);
            }));
        });
    }

    void ShowStopped(string why)
    {
        connDot.Set(false, false); connText.Text = "Stopped";
        Row(dIpad, tIpad, false, "Not available while the bridge is stopped");
        Row(dSim, tSim, false, "Not available while the bridge is stopped");
        Row(dLink, tLink, false, "Not available while the bridge is stopped");
        lede.Text = string.IsNullOrEmpty(why) ? "The bridge is not running. Press Restart bridge. The Log page shows what it printed." : why;
        if (restart.Visibility != Visibility.Visible) { restart.Visibility = Visibility.Visible; restart.Opacity = 0; Pal.Fade(restart, 1, 300); }
    }

    public void ApplyStatus(object s)
    {
        bool sim = Json.Bool(s, "sim", "connected"), link = Json.Bool(s, "link", "connected");
        int apps = Json.Int(s, "bridge", "apps");
        string title = Json.Str(s, "sim", "aircraftTitle");
        restart.Visibility = Visibility.Collapsed;
        connDot.Set(true, false); connText.Text = "Running";
        version.Text = "Version " + (Json.Str(s, "bridge", "version") ?? "");
        Row(dIpad, tIpad, apps > 0, apps > 0 ? "Connected" + (apps > 1 ? " (" + apps + " devices)" : "") : "Waiting for the app");
        Row(dSim, tSim, sim, sim ? (string.IsNullOrEmpty(title) ? "Connected" : title) : "Waiting. Start the sim.");
        Row(dLink, tLink, link, link ? "Connected" : "Not connected (optional)");
        string text = apps > 0 && sim ? "Everything is connected. Leave this running while you fly." : "The bridge is running. Open SimPilot on your iPad and start MSFS 2024.";
        if (lede.Text != text) lede.Text = text;
    }

    static void Row(Dot d, TextBlock t, bool ok, string text) { d.Set(ok, false); if (t.Text != text) t.Text = text; }

    static string Bytes(long bytes)
    {
        return bytes < 1048576 ? Math.Max(1, bytes / 1024) + " KB" : (bytes / 1048576) + " MB";
    }

    public void ApplyInfo(object info)
    {
        airports.Children.Clear();
        int count = 0;
        foreach (object a in Json.List(info, "cache", "airports"))
        {
            if (count++ > 0) airports.Children.Add(Divider());
            Grid g = new Grid { Margin = new Thickness(18, 15, 18, 15) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Dot dot = new Dot { Margin = new Thickness(-5, 0, 9, 0) }; dot.Set(true, false);
            StackPanel s = new StackPanel();
            TextBlock t = Pal.Text(Json.Str(a, "icao") ?? "", 14, Pal.Fg, false); t.FontWeight = FontWeights.Medium;
            s.Children.Add(t); s.Children.Add(Pal.Text(Bytes(Json.Long(a, "bytes")) + " on disk", 13, Pal.Fg2, false));
            Grid.SetColumn(s, 1);
            TextBlock n = Pal.Text(Json.Int(a, "charts") + " charts", 12.5, Pal.Fg2, false); n.FontFamily = Pal.Mono;
            Grid.SetColumn(n, 2);
            g.Children.Add(dot); g.Children.Add(s); g.Children.Add(n);
            airports.Children.Add(g);
        }
        if (count == 0) airports.Children.Add(new TextBlock { Text = "No charts yet. Open an airport in the iPad app with the chart panel running.", Foreground = Pal.B(Pal.Fg2), FontSize = 13.5, Margin = new Thickness(18), TextWrapping = TextWrapping.Wrap });
        cacheSize.Text = count + (count == 1 ? " airport, " : " airports, ") + Bytes(Json.Long(info, "cache", "bytes")) + " on disk";
    }

    void RenderAddress()
    {
        string a = firstAddress.Length == 0 ? "no network found" : firstAddress;
        string shown = ipHidden ? MaskDigits(a) : a;
        addr.Text = shown;
        topIp.Text = firstAddress.Length == 0 ? "" : (ipHidden ? MaskDigits(firstAddress) : firstAddress).Split(':')[0];
    }

    static string MaskDigits(string s)
    {
        StringBuilder b = new StringBuilder();
        foreach (char c in s) b.Append(char.IsDigit(c) ? '•' : c);
        return b.ToString();
    }

    void ApplyOutput()
    {
        string text = "The bridge isn't answering. This is what it printed:\n\n" + host.Output();
        if (text == lastLog) return;
        lastLog = text;
        logText.Text = text;
        logScroll.ScrollToEnd();
    }

    public void ApplyLog(object log)
    {
        StringBuilder sb = new StringBuilder();
        foreach (object e in Json.List(log, "entries"))
        {
            DateTime when;
            string time = Json.Str(e, "time") ?? "";
            string shown = DateTime.TryParse(time, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out when) ? when.ToLocalTime().ToString("HH:mm:ss") : time;
            string level = Json.Str(e, "level");
            sb.Append(shown).Append("  ").Append(level == "warn" ? "! " : level == "error" ? "!! " : "").Append('[').Append(Json.Str(e, "scope")).Append("] ").Append(Json.Str(e, "message")).Append('\n');
        }
        string text = sb.ToString().TrimEnd('\n');
        if (text == lastLog) return;
        lastLog = text;
        bool stick = logScroll.VerticalOffset >= logScroll.ScrollableHeight - 8;
        logText.Text = text;
        if (stick) logScroll.ScrollToEnd();
    }
}

class TrayApp
{
    readonly string dir = AppDomain.CurrentDomain.BaseDirectory;
    readonly bool startHidden;
    readonly EventWaitHandle showEvent;
    readonly Forms.NotifyIcon tray;
    readonly Forms.ToolStripMenuItem restartItem;
    MainWindow window;
    Process node;
    bool quitting, balloonShown;
    public bool DeferQuit;
    public string LastError;
    readonly List<string> output = new List<string>();

    /// True while the node.exe this program started is alive.
    public bool BridgeRunning { get { try { return node != null && !node.HasExited; } catch (Exception) { return false; } } }

    public string Output() { lock (output) return output.Count == 0 ? "(nothing yet)" : string.Join("\n", output.ToArray()); }

    void Capture(string line, bool error)
    {
        if (line == null) return;
        lock (output)
        {
            output.Add(line);
            if (output.Count > 300) output.RemoveAt(0);
        }
        string t = line.Trim();
        // Bridge log lines look like "12:00:01.234 ERROR [http] message"; warnings and stack frames are not the reason it stopped.
        bool logLine = Regex.IsMatch(t, "^\\d\\d:\\d\\d:\\d\\d");
        if (!error || t.Length == 0 || t.StartsWith("at ") || (logLine && !t.Contains(" ERROR "))) return;
        int cut = t.IndexOf("] ");
        LastError = logLine && cut > 0 ? t.Substring(cut + 2) : t;
    }

    public TrayApp(bool minimized, EventWaitHandle showEvent)
    {
        startHidden = minimized;
        this.showEvent = showEvent;
        Drawing.Icon icon = null;
        try { icon = Drawing.Icon.ExtractAssociatedIcon(System.Windows.Forms.Application.ExecutablePath); } catch (Exception) { }
        Forms.ContextMenuStrip menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open SimPilot Bridge", null, delegate { ShowWindow(); });
        restartItem = new Forms.ToolStripMenuItem("Restart bridge", null, delegate { RestartBridge(); });
        restartItem.Visible = false;
        menu.Items.Add(restartItem);
        menu.Items.Add("Quit", null, delegate { Quit(); });
        tray = new Forms.NotifyIcon();
        tray.Text = "SimPilot Bridge";
        tray.Icon = icon ?? Drawing.SystemIcons.Application;
        tray.ContextMenuStrip = menu;
        tray.Visible = true;
        tray.DoubleClick += delegate { ShowWindow(); };
    }

    public void Begin()
    {
        StartBridge();
        Thread listener = new Thread(delegate ()
        {
            while (!quitting)
            {
                showEvent.WaitOne();
                if (quitting) break;
                Application.Current.Dispatcher.BeginInvoke(new Action(ShowWindow));
            }
        });
        listener.IsBackground = true;
        listener.Start();
        if (!startHidden) ShowWindow();
    }

    void ShowWindow()
    {
        if (quitting) return;
        if (window == null) window = new MainWindow(this);
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public void WindowHidden()
    {
        if (balloonShown) return;
        balloonShown = true;
        tray.ShowBalloonTip(4000, "SimPilot Bridge is still running", "Right-click the tray icon to quit it.", Forms.ToolTipIcon.Info);
    }

    // ---- bridge process ----

    public void RestartBridge() { StartBridge(); }

    void StartBridge()
    {
        string exe = System.IO.Path.Combine(dir, "node.exe");
        string script = System.IO.Path.Combine(dir, "bridge.cjs");
        if (!File.Exists(exe) || !File.Exists(script))
        {
            MessageBox.Show("node.exe or bridge.cjs is missing next to this program. Extract the whole SimPilot for PC folder and run it from there.", "SimPilot Bridge", MessageBoxButton.OK, MessageBoxImage.Warning);
            Quit();
            return;
        }
        KillStrays(exe);
        restartItem.Visible = false;
        LastError = null;
        lock (output) output.Clear();
        ProcessStartInfo psi = new ProcessStartInfo(exe, "\"" + script + "\"");
        psi.WorkingDirectory = dir;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        // Redirect all three: with a hidden console as stdin, the bridge would wait forever for Enter after an error.
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        try
        {
            node = new Process();
            node.StartInfo = psi;
            node.EnableRaisingEvents = true;
            node.Exited += OnNodeExited;
            node.OutputDataReceived += delegate (object o, DataReceivedEventArgs a) { Capture(a.Data, false); };
            node.ErrorDataReceived += delegate (object o, DataReceivedEventArgs a) { Capture(a.Data, true); };
            node.Start();
            node.StandardInput.Close();
            node.BeginOutputReadLine();
            node.BeginErrorReadLine();
        }
        catch (Exception ex) { LastError = "Couldn't start the bridge: " + ex.Message; Stopped(LastError); }
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
        Application.Current.Dispatcher.BeginInvoke(new Action(delegate
        {
            // Exit code 0 is the bridge shutting itself down for an update or an uninstall.
            if (quitting || DeferQuit) return;
            if (code == 0) { Quit(); return; }
            if (string.IsNullOrEmpty(LastError)) LastError = "SimPilot Bridge stopped (exit code " + code + "). Press Restart bridge.";
            Stopped(LastError);
        }));
    }

    void Stopped(string message)
    {
        restartItem.Visible = true;
        tray.Text = "SimPilot Bridge - stopped";
        tray.ShowBalloonTip(6000, "SimPilot Bridge", message.Length > 250 ? message.Substring(0, 250) : message, Forms.ToolTipIcon.Warning);
    }

    public void Quit()
    {
        if (quitting) return;
        quitting = true;
        try { showEvent.Set(); } catch (Exception) { }
        try { if (node != null && !node.HasExited) node.Kill(); } catch (Exception) { }
        tray.Visible = false;
        tray.Dispose();
        Application.Current.Shutdown();
    }
}
