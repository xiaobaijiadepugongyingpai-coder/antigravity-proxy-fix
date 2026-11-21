/*
 * AntigravityProxy: lightweight Windows GUI launcher for Antigravity.
 *
 * Injects HTTP_PROXY / HTTPS_PROXY / NO_PROXY into the Antigravity process
 * tree only (zero global environment pollution), while preserving and
 * forwarding ALL command-line arguments verbatim (e.g. --remote-debugging-port
 * used by plugins such as Antigrative Dashboard / antigravity-pulse).
 *
 * Build via scripts\build-desktop-launcher.ps1 (uses built-in csc.exe):
 *   csc.exe /nologo /target:winexe /optimize+ ^
 *     /out:%USERPROFILE%\.agy-shim\AntigravityProxy.exe ^
 *     src\AntigravityProxy.cs src\ProxyCommon.cs
 *
 * Proxy discovery order (skipped if HTTP_PROXY/HTTPS_PROXY already set):
 *   1. ANTIGRAVITY_PROXY environment variable
 *   2. proxy.conf in launcher directory or %USERPROFILE%\.agy-shim\proxy.conf
 *   3. Auto-probe http://127.0.0.1:7897, 7890, 10809
 * If no candidate port responds, launches Antigravity without injecting proxy
 * variables so offline / direct usage is never broken.
 */

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("AntigravityProxy")]
[assembly: AssemblyDescription("Per-app proxy launcher for Google Antigravity")]
[assembly: AssemblyProduct("Antigravity Proxy Fix")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]

namespace AntigravityProxyFix
{
    internal static class Program
    {
        private const uint MbOk = 0x00000000;
        private const uint MbIconError = 0x00000010;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        [STAThread]
        private static int Main()
        {
            string selfPath = Assembly.GetExecutingAssembly().Location;
            string selfDir = string.IsNullOrEmpty(selfPath)
                ? AppDomain.CurrentDomain.BaseDirectory
                : Path.GetDirectoryName(selfPath);

            string realExe = LocateRealExe();
            if (string.IsNullOrEmpty(realExe))
            {
                string expected = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    @"Programs\antigravity\Antigravity.exe");
                ShowError(
                    "Antigravity.exe not found.\n\nExpected:\n" + expected +
                    "\n\nYou can also set ANTIGRAVITY_REAL_EXE to the full path.");
                return 1;
            }

            ProxyCommon.MaybeSetProxy("ANTIGRAVITY_PROXY", selfDir);

            string rawArgs = ProxyCommon.ExtractRawArguments();

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = realExe;
                psi.Arguments = rawArgs;
                psi.UseShellExecute = false;
                Process.Start(psi);
                return 0;
            }
            catch (Exception ex)
            {
                ShowError("Failed to launch Antigravity:\n\n" + realExe + "\n\n" + ex.Message);
                return 1;
            }
        }

        private static void ShowError(string message)
        {
            if (string.Equals(Environment.GetEnvironmentVariable("ANTIGRAVITY_NO_GUI_ERROR"), "1", StringComparison.Ordinal))
            {
                return;
            }
            try
            {
                MessageBoxW(IntPtr.Zero, message, "AntigravityProxy", MbOk | MbIconError);
            }
            catch
            {
                // Ignore UI errors in non-interactive sessions.
            }
        }

        private static string LocateRealExe()
        {
            string overrideExe = Environment.GetEnvironmentVariable("ANTIGRAVITY_REAL_EXE");
            if (!string.IsNullOrEmpty(overrideExe) && File.Exists(overrideExe))
            {
                return overrideExe;
            }

            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrEmpty(localAppData))
            {
                string candidate = Path.Combine(localAppData, @"Programs\antigravity\Antigravity.exe");
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }

            return null;
        }
    }
}
