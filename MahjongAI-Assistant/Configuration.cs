using System;
using Dalamud.Configuration;

namespace MahjongAI_Assistant;

[Serializable]
public sealed class Configuration : IPluginConfiguration
{
    public int Version { get; set; } = 1;
    public string AccountId { get; set; } = "MAIN_A";
    public string AccountGroup { get; set; } = "大号";
    public string MortalBridgeUrl { get; set; } = "http://127.0.0.1:8765";

    public void Save() => Plugin.PluginInterface.SavePluginConfig(this);
}
