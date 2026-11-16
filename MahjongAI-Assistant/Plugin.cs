using System.Collections.Concurrent;
using Dalamud.Game.Addon.Lifecycle;
using Dalamud.Game.Addon.Lifecycle.AddonArgTypes;
using Dalamud.Game.Command;
using Dalamud.IoC;
using Dalamud.Plugin;
using Dalamud.Plugin.Services;
using Dalamud.Interface.Windowing;
using MahjongAI_Assistant.Windows;

namespace MahjongAI_Assistant;

public sealed class Plugin : IDalamudPlugin
{
    [PluginService] internal static IDalamudPluginInterface PluginInterface { get; private set; } = null!;
    [PluginService] internal static ICommandManager CommandManager { get; private set; } = null!;
    [PluginService] internal static IPlayerState PlayerState { get; private set; } = null!;
    [PluginService] internal static IAddonLifecycle AddonLifecycle { get; private set; } = null!;

    private const string CommandName = "/maia";
    public Configuration Configuration { get; }
    private readonly WindowSystem windowSystem = new("MahjongAIAssistant");
    private readonly MainWindow mainWindow;
    private readonly ConcurrentQueue<string> addonEvents = new();
    private readonly IAddonLifecycle.AddonEventDelegate addonSetupHandler;

    public IReadOnlyList<string> RecentAddonEvents => addonEvents.ToArray();

    public Plugin()
    {
        Configuration = PluginInterface.GetPluginConfig() as Configuration ?? new Configuration();
        Configuration.Save();
        addonSetupHandler = OnAddonSetup;
        AddonLifecycle.RegisterListener(AddonEvent.PostSetup, addonSetupHandler);
        AddonLifecycle.RegisterListener(AddonEvent.PostOpen, addonSetupHandler);

        mainWindow = new MainWindow(this);
        windowSystem.AddWindow(mainWindow);
        CommandManager.AddHandler(CommandName, new CommandInfo((_, _) => mainWindow.Toggle())
        {
            HelpMessage = "Open Mahjong AI Assistant."
        });
        PluginInterface.UiBuilder.Draw += windowSystem.Draw;
        PluginInterface.UiBuilder.OpenMainUi += mainWindow.Toggle;
    }

    private void OnAddonSetup(AddonEvent type, AddonArgs args)
    {
        if (string.IsNullOrWhiteSpace(args.AddonName) || args.AddonName == AddonArgs.InvalidAddon)
            return;
        addonEvents.Enqueue($"{DateTime.Now:HH:mm:ss}  {type}  {args.AddonName}");
        while (addonEvents.Count > 100) addonEvents.TryDequeue(out _);
    }

    public void Dispose()
    {
        AddonLifecycle.UnregisterListener(AddonEvent.PostSetup, addonSetupHandler);
        AddonLifecycle.UnregisterListener(AddonEvent.PostOpen, addonSetupHandler);
        PluginInterface.UiBuilder.Draw -= windowSystem.Draw;
        PluginInterface.UiBuilder.OpenMainUi -= mainWindow.Toggle;
        CommandManager.RemoveHandler(CommandName);
        windowSystem.RemoveAllWindows();
        mainWindow.Dispose();
    }
}
