using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Zerm.Core.Dictation;

namespace Zerm.App.Views;

/// <summary>
/// Test aid: "Zerm.exe --snapshot &lt;dir&gt;" renders every page, the onboarding steps, the recorder
/// states and a toast to PNG files off-screen, then exits. Lets the UI be reviewed without touching
/// the user's desktop.
/// </summary>
public static class Snapshotter
{
    public static async Task RunAsync(string dir)
    {
        Directory.CreateDirectory(dir);
        var errors = new List<string>();
        var shell = ShellWindow.CreateForSnapshot();
        shell.Left = -20000;
        shell.Top = 0;
        shell.ShowActivated = false;
        shell.Show();
        foreach (var page in new[] { "Dashboard", "History", "Models", "Vocabulary", "Speak", "ReadAloudHistory", "Voices", "TranscribeFile", "Enhancement", "Insights", "PowerModes", "AudioInput", "Settings" })
        {
            try
            {
                shell.Navigate(page);
                await Settle();
                // Redraw in place (what downloads, toggles and refreshes do) to catch reparenting bugs.
                if (shell.CurrentContent is { } current && current.GetType().GetMethod("Render",
                        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public, Type.EmptyTypes) is { } render)
                {
                    try { render.Invoke(current, null); render.Invoke(current, null); }
                    catch (System.Reflection.TargetInvocationException tie) { errors.Add($"{page} re-render: {tie.InnerException}"); }
                    await Settle();
                }
                Render(shell, Path.Combine(dir, $"page-{page}.png"));
                // Tall pages: also render the full scrollable content.
                if (shell.CurrentContent is FrameworkElement fe && FindScroll(fe) is { } scroll && scroll.Content is FrameworkElement inner)
                {
                    inner.Measure(new Size(scroll.ActualWidth, double.PositiveInfinity));
                    inner.Arrange(new Rect(inner.DesiredSize));
                    Render(inner, Path.Combine(dir, $"full-{page}.png"));
                    scroll.InvalidateMeasure();
                }
            }
            catch (Exception ex)
            {
                errors.Add($"{page}: {ex}");
            }
        }
        shell.Hide();

        var onboarding = new OnboardingWindow { Left = -20000, ShowActivated = false };
        onboarding.Show();
        for (var step = 0; step < 5; step++)
        {
            try
            {
                onboarding.GoTo(step);
                await Settle();
                Render(onboarding, Path.Combine(dir, $"onboarding-{step}.png"));
            }
            catch (Exception ex)
            {
                errors.Add($"onboarding {step}: {ex}");
            }
        }
        onboarding.Close();

        var host = AppHost.Current;
        foreach (var state in new[] { RecorderState.Recording, RecorderState.Transcribing, RecorderState.Enhancing, RecorderState.Speaking })
        {
            try
            {
                RecorderOverlay.ShowRecorder();
                host.Ui.SetState(state);
                await Settle(400);
                Render(RecorderOverlay.Instance, Path.Combine(dir, $"recorder-{state}.png"));
            }
            catch (Exception ex)
            {
                errors.Add($"recorder {state}: {ex}");
            }
        }
        RecorderOverlay.HideRecorder();
        host.Ui.SetState(RecorderState.Idle);

        ToastWindow.Show("Enhancement timed out. Your original text was kept.", ToastKind.Warning, TimeSpan.FromSeconds(3),
            new ToastAction("Copy Refined Text", () => { }));
        await Settle();
        foreach (var w in Application.Current.Windows.OfType<ToastWindow>()) Render(w, Path.Combine(dir, "toast.png"));

        // The Models page download flow, end to end (ZERM_SNAPSHOT_DOWNLOAD=<model name>).
        if (Environment.GetEnvironmentVariable("ZERM_SNAPSHOT_DOWNLOAD") is { Length: > 0 } modelName)
        {
            try
            {
                shell.Show();
                shell.Navigate("Models");
                await Settle();
                var models = (Pages.ModelsPage)shell.CurrentContent;
                var model = Core.Models.TranscriptionModelRegistry.Find(modelName)!;
                if (!model.IsDownloaded)
                    typeof(Pages.ModelsPage).GetMethod("StartDownload", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                        .Invoke(models, [model]);
                var sw = System.Diagnostics.Stopwatch.StartNew();
                while (host.Downloads.Get(modelName) != null && sw.Elapsed < TimeSpan.FromMinutes(10)) await Task.Delay(500);
                await Settle(1000);
                Render(shell, Path.Combine(dir, "download-done.png"));
                errors.Add($"DOWNLOAD {modelName}: downloaded={model.IsDownloaded} in {sw.Elapsed.TotalSeconds:F0}s, default={host.Settings.CurrentTranscriptionModel}");
                if (model.IsDownloaded)
                {
                    var samples = Core.Audio.AudioUtil.LoadAs16kMono(Environment.GetEnvironmentVariable("ZERM_SNAPSHOT_WAV")!);
                    var result = await host.Transcription.TranscribeAsync(model, "", samples, "auto", [], [], CancellationToken.None);
                    errors.Add($"TRANSCRIBE with {modelName}: [{result.Text}] in {result.Elapsed.TotalMilliseconds:F0} ms");
                }
            }
            catch (Exception ex)
            {
                errors.Add("DOWNLOAD FAILED " + ex);
            }
        }

        await File.WriteAllLinesAsync(Path.Combine(dir, "errors.txt"), errors);
    }

    private static System.Windows.Controls.ScrollViewer? FindScroll(DependencyObject root)
    {
        if (root is System.Windows.Controls.ScrollViewer sv) return sv;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
            if (FindScroll(VisualTreeHelper.GetChild(root, i)) is { } found) return found;
        return null;
    }

    private static async Task Settle(int ms = 250)
    {
        await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        await Task.Delay(ms);
        await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }

    private static void Render(FrameworkElement element, string path)
    {
        var width = (int)Math.Ceiling(element.ActualWidth);
        var height = (int)Math.Ceiling(Math.Min(element.ActualHeight, 6000));
        if (width <= 0 || height <= 0) return;
        var bmp = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            // Windows' own background (the visual has none of its own when transparent).
            var bg = element is Window w && w.AllowsTransparency ? Brushes.Gray
                : (Brush?)Application.Current.TryFindResource("ApplicationBackgroundBrush") ?? Brushes.White;
            dc.DrawRectangle(bg, null, new Rect(0, 0, width, height));
            dc.DrawRectangle(new VisualBrush(element), null, new Rect(0, 0, width, height));
        }
        bmp.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bmp));
        using var file = File.Create(path);
        encoder.Save(file);
    }
}
