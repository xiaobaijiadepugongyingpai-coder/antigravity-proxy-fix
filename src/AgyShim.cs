/*
 * AgyShim: zero-dependency Windows CLI proxy shim for agy.
 *
 * Compiles with Windows built-in .NET Framework 4 csc.exe via
 * scripts\build-cli-shim.ps1 (no MinGW-w64 installation required):
 *   csc.exe /nologo /target:exe /optimize+ ^
 *     /out:%LOCALAPPDATA%\agy\shim\agy.exe ^
 *     src\AgyShim.cs src\ProxyCommon.cs
 *
 * Behavior:
 *   1. If HTTP_PROXY / HTTPS_PROXY is already set, pass through untouched.
 *   2. Otherwise probe candidates in order:
 *        AGY_PROXY -> <shim dir>\proxy.conf -> %USERPROFILE%\.agy-shim\proxy.conf
 *        -> http://127.0.0.1:7897 -> 7890 -> 10809
 *   3. Inject HTTPS_PROXY / HTTP_PROXY / NO_PROXY into the child process only
 *      if a candidate port responds. If none responds, do not inject anything.
 *   4. Launch real agy.exe with verbatim arguments, shared console stdio/TUI,
 *      and exact exit code passthrough.
 *   5. Print shim version on --version / -V / --shim-version.
 */

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("AgyShim")]
[assembly: AssemblyDescription("Per-app proxy shim for Antigravity CLI (agy)")]
[assembly: AssemblyProduct("Antigravity Proxy Fix")]
[assembly: AssemblyVersion("2.1.0.0")]
[assembly: AssemblyFileVersion("2.1.0.0")]

namespace AntigravityProxyFix
{
    internal static class AgyShimProgram
    {
        private const string ShimVersion = "2.1.0";

        private static int Main(string[] args)
        {
            if (args.Length >= 1 &&
                (args[0] == "--version" || args[0] == "-V" || args[0] == "--shim-version"))
            {
                Console.WriteLine("agy-shim " + ShimVersion + " (cs)");
                return 0;
            }

            string selfPath = Assembly.GetExecutingAssembly().Location;
            if (string.IsNullOrEmpty(selfPath))
            {
                Console.Error.WriteLine("agy-shim: cannot determine self path");
                return 1;
            }
            string selfFull = Path.GetFullPath(selfPath);
            string selfDir = Path.GetDirectoryName(selfFull);

            string realExe = LocateRealExe(selfFull, selfDir);
            if (string.IsNullOrEmpty(realExe))
            {
                Console.Error.WriteLine("agy-shim: cannot locate real agy.exe near " + selfDir);
                return 1;
            }

            ProxyCommon.MaybeSetProxy("AGY_PROXY", selfDir);

            string rawArgs = ProxyCommon.ExtractRawArguments();

            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
            {
                // Let the child agy.exe handle Ctrl+C while the shim waits for its exit code.
                e.Cancel = true;
            };

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = realExe;
                psi.Arguments = rawArgs;
                psi.UseShellExecute = false;

                using (Process child = Process.Start(psi))
                {
                    if (child == null)
                    {
                        Console.Error.WriteLine("agy-shim: failed to start " + realExe);
                        return 1;
                    }
                    child.WaitForExit();
                    return child.ExitCode;
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("agy-shim: failed to launch " + realExe + ": " + ex.Message);
                return 1;
            }
        }

        private static bool IsDifferentExistingFile(string candidate, string selfFull)
        {
            if (string.IsNullOrEmpty(candidate) || !File.Exists(candidate))
            {
                return false;
            }
            try
            {
                string full = Path.GetFullPath(candidate);
                return !string.Equals(full, selfFull, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static string LocateRealExe(string selfFull, string selfDir)
        {
            string overrideExe = Environment.GetEnvironmentVariable("AGY_REAL_EXE");
            if (IsDifferentExistingFile(overrideExe, selfFull))
            {
                return Path.GetFullPath(overrideExe);
            }

            string[] probes = new string[]
            {
                Path.Combine(selfDir, @"bin\agy.exe"),
                Path.Combine(selfDir, @"..\bin\agy.exe"),
                Path.Combine(selfDir, "agy-real.exe")
            };

            for (int i = 0; i < probes.Length; i++)
            {
                if (IsDifferentExistingFile(probes[i], selfFull))
                {
                    return Path.GetFullPath(probes[i]);
                }
            }

            return null;
        }
    }
}
