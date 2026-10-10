using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Craft Suite Setup")]
[assembly: AssemblyDescription("Graphical community installer for unmodified official Craft app releases.")]
[assembly: AssemblyCompany("Community installer")]
[assembly: AssemblyProduct("Craft Suite Setup")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

internal static class CraftSetup {
    [STAThread]
    private static int Main(string[] args) {
        Application.EnableVisualStyles();
        bool quiet = false;
        string diagnostics = null;
        var forwarded = new System.Collections.Generic.List<string>();
        for (int i = 0; i < args.Length; i++) {
            if (args[i] == "--quiet") { quiet = true; continue; }
            if (args[i] == "--diagnostics" && i + 1 < args.Length) { diagnostics = args[++i]; continue; }
            forwarded.Add(args[i]);
        }
        string root = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "InstallerData");
        string script = Path.Combine(root, "Install.ps1");
        try {
            if (!File.Exists(script) || !File.Exists(Path.Combine(root, "bundle.json")) || !Directory.Exists(Path.Combine(root, "Payloads"))) {
                return Error("Please extract the entire ZIP first, then run Setup.exe from the extracted folder. Keep Setup.exe alongside the included files.", quiet, diagnostics, 2);
            }
            if (!Environment.Is64BitOperatingSystem) {
                return Error("This bundle needs Windows 10 or 11 on a 64-bit x64 PC.", quiet, diagnostics, 3);
            }
            string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(shell)) return Error("Windows PowerShell is unavailable on this computer. No changes were made.", quiet, diagnostics, 4);
            var command = new StringBuilder("-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ");
            command.Append(Quote(script));
            foreach (string arg in forwarded) command.Append(" ").Append(Quote(arg));
            var info = new ProcessStartInfo(shell, command.ToString());
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            var output = new StringBuilder();
            using (var process = new Process()) {
                process.StartInfo = info;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                int result = process.ExitCode;
                if (diagnostics != null) File.WriteAllText(diagnostics, output.ToString());
                if (result != 0) {
                    string detail = output.ToString().Trim();
                    if (detail.Length > 1800) detail = detail.Substring(0, 1800);
                    return Error("Setup could not finish. Your existing files have been preserved.\n\n" + detail, quiet, diagnostics, result);
                }
                return 0;
            }
        } catch (Exception e) {
            return Error("Setup could not start.\n\n" + e.Message, quiet, diagnostics, 5);
        }
    }
    private static int Error(string message, bool quiet, string diagnostics, int code) {
        if (diagnostics != null) { try { File.WriteAllText(diagnostics, message); } catch { } }
        if (!quiet) MessageBox.Show(message, "Craft Suite Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
        return code;
    }
    private static string Quote(string value) {
        // Windows argv quoting: preserve spaces, apostrophes, ampersands and trailing backslashes.
        var text = new StringBuilder("\""); int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { text.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
            text.Append('\\', slashes).Append(c); slashes = 0;
        }
        text.Append('\\', slashes * 2).Append('"'); return text.ToString();
    }
}
