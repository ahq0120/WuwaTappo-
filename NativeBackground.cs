using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WuwaBackgroundNative {
    const long NoActivate = 0x08000000;
    const int ExStyle = -20;
    public struct POINT { public int X, Y; }
    public struct RECT { public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr param);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr window, ref POINT point);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW", SetLastError=true)] static extern IntPtr GetLong64(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW", SetLastError=true)] static extern int GetLong32(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW", SetLastError=true)] static extern IntPtr SetLong64(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll", EntryPoint="SetWindowLongW", SetLastError=true)] static extern int SetLong32(IntPtr window, int index, int value);
    [DllImport("kernel32.dll")] static extern void SetLastError(uint error);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", SetLastError=true)] static extern bool PostMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    static long Style(IntPtr window) { return IntPtr.Size == 8 ? GetLong64(window, ExStyle).ToInt64() : GetLong32(window, ExStyle); }
    static void SetStyle(IntPtr window, long style) {
        SetLastError(0);
        IntPtr previous = IntPtr.Size == 8 ? SetLong64(window, ExStyle, new IntPtr(style)) : new IntPtr(SetLong32(window, ExStyle, unchecked((int)style)));
        int error = Marshal.GetLastWin32Error();
        if (previous == IntPtr.Zero && error != 0) throw new Win32Exception(error, "Cannot update Wuwa window style");
        if (!SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x237)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot apply window style");
    }
    public static uint ProcessOf(IntPtr window) { uint p; GetWindowThreadProcessId(window, out p); return p; }
    public static bool IsTargetForeground(IntPtr window) {
        IntPtr current = GetForegroundWindow();
        return current != IntPtr.Zero && (GetAncestor(current, 2) == window || ProcessOf(current) == ProcessOf(window));
    }
    public sealed class WindowGuard : IDisposable {
        IntPtr window; uint process; bool added; bool disposed;
        public WindowGuard(IntPtr target) {
            if (!IsWindow(target)) throw new InvalidOperationException("Wuwa window disappeared");
            window = target; process = ProcessOf(target);
            long before = Style(window); added = (before & NoActivate) == 0;
            try { SetStyle(window, before | NoActivate); Verify(); }
            catch { Dispose(); throw; }
        }
        public void Verify() {
            if (!IsWindow(window) || ProcessOf(window) != process) throw new InvalidOperationException("Wuwa window changed");
            if ((Style(window) & NoActivate) == 0) throw new InvalidOperationException("Wuwa reset the no-activation style; test stopped");
        }
        public void Dispose() {
            if (disposed) return;
            disposed = true;
            if (added && IsWindow(window) && ProcessOf(window) == process) SetStyle(window, Style(window) & ~NoActivate);
        }
    }
    // Polling observes foreground changes; it cannot prevent or prove absence of very brief changes.
    public sealed class FocusProbe : IDisposable {
        readonly IntPtr target; readonly uint process; readonly IntPtr initial;
        readonly Thread worker; volatile bool running = true;
        int changes; int targetSeen;
        volatile string phase = "before-guard";
        readonly ConcurrentQueue<string> events = new ConcurrentQueue<string>();
        public void Mark(string value) { phase = value; }
        public string[] GetEvents() { return events.ToArray(); }
        static string Describe(IntPtr window) {
            uint pid = ProcessOf(window);
            string name = "none";
            if (pid != 0) {
                try { using (var p = Process.GetProcessById((int)pid)) { name = p.ProcessName; } }
                catch { name = "unavailable"; }
            }
            var cls = new StringBuilder(256);
            GetClassName(window, cls, cls.Capacity);
            return "hwnd=0x" + window.ToInt64().ToString("X") + "; pid=" + pid + "; process=" + name + "; class=" + cls;
        }
        void Record(IntPtr window) {
            if (events.Count < 200) events.Enqueue(DateTime.Now.ToString("HH:mm:ss.fff") + " [" + phase + "] " + Describe(window));
        }
        public int Changes { get { return Volatile.Read(ref changes); } }
        public bool TargetSeen { get { return Volatile.Read(ref targetSeen) != 0; } }
        public FocusProbe(IntPtr window) {
            target = window; process = ProcessOf(window); initial = GetForegroundWindow();
            Record(initial);
            worker = new Thread(Watch); worker.IsBackground = true; worker.Start();
        }
        void Watch() {
            IntPtr previous = initial;
            while (running) {
                IntPtr current = GetForegroundWindow();
                if (current != previous) { Interlocked.Increment(ref changes); previous = current; Record(current); }
                if (current != IntPtr.Zero && (GetAncestor(current, 2) == target || ProcessOf(current) == process)) Interlocked.Exchange(ref targetSeen, 1);
                Thread.Sleep(5);
            }
        }
        public void Dispose() { running = false; worker.Join(1000); }
    }
    public static IntPtr PackClientPoint(int x, int y) {
        if (x < 0 || y < 0 || x > 32767 || y > 32767) throw new ArgumentOutOfRangeException("point");
        return new IntPtr((y << 16) | (x & 0xffff));
    }
    static void CheckedPost(IntPtr root, IntPtr target, uint rootProcess, uint message, UIntPtr state, IntPtr point) {
        var name = new StringBuilder(256); GetClassName(target, name, name.Capacity);
        if (!IsWindow(root) || ProcessOf(root) != rootProcess || !IsChild(root, target) ||
            GetAncestor(target, 2) != root || name.ToString() != "Chrome_RenderWidgetHostHWND")
            throw new InvalidOperationException("Input window changed; no further messages sent");
        if (!PostMessageW(target, message, state, point))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Targeted mouse message failed; check Wuwa before retrying");
    }
    public static string ClickWebView(IntPtr root, int screenX, int screenY) {
        if (!IsWindow(root)) throw new InvalidOperationException("Wuwa window disappeared");
        if (IsTargetForeground(root)) throw new InvalidOperationException("Switch to another application first");
        if ((Style(root) & NoActivate) == 0) throw new InvalidOperationException("No-activation guard is not active");
        IntPtr oldDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            var matches = new List<IntPtr>(); long smallest = long.MaxValue;
            EnumProc callback = delegate(IntPtr child, IntPtr ignored) {
                var name = new StringBuilder(256); GetClassName(child, name, name.Capacity);
                if (name.ToString() != "Chrome_RenderWidgetHostHWND" || !IsWindowVisible(child)) return true;
                RECT r;
                if (!GetWindowRect(child, out r) || screenX < r.Left || screenX >= r.Right || screenY < r.Top || screenY >= r.Bottom) return true;
                long area = (long)(r.Right-r.Left) * (r.Bottom-r.Top);
                if (area <= 0) return true;
                if (area < smallest) { smallest = area; matches.Clear(); }
                if (area == smallest) matches.Add(child);
                return true;
            };
            EnumChildWindows(root, callback, IntPtr.Zero);
            if (matches.Count != 1) throw new InvalidOperationException("Cannot uniquely locate the WebView input window (count=" + matches.Count + ")");
            IntPtr target = matches[0];
            if (!IsChild(root, target) || GetAncestor(target, 2) != root) throw new InvalidOperationException("Input window is not inside Wuwa");
            var point = new POINT { X = screenX, Y = screenY }; RECT client;
            if (!ScreenToClient(target, ref point) || !GetClientRect(target, out client) || point.X < 0 || point.Y < 0 || point.X >= client.Right || point.Y >= client.Bottom) throw new InvalidOperationException("Chest point outside WebView client area");
            IntPtr pos = PackClientPoint(point.X, point.Y);
            if (IsTargetForeground(root)) throw new InvalidOperationException("Wuwa became foreground before dispatch");
            // No WM_MOUSEACTIVATE, focus/activation APIs, cursor movement, or input broadcast.
            uint owner = ProcessOf(root);
            CheckedPost(root, target, owner, 0x0200, UIntPtr.Zero, pos);
            CheckedPost(root, target, owner, 0x0201, new UIntPtr(1), pos);
            Thread.Sleep(60);
            CheckedPost(root, target, owner, 0x0202, UIntPtr.Zero, pos);
            return "Chrome_RenderWidgetHostHWND; client=" + point.X + "," + point.Y;
        } finally { if (oldDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(oldDpi); }
    }
}
