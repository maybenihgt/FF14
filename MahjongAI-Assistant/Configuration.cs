using System;
using Dalamud.Configuration;

namespace MahjongAI_Assistant;

[Serializable]
public sealed class Configuration : IPluginConfiguration
{
    public int Version { get; set; } = 1;
    public string AccountId { get; set; } = "MAIN_A";
    public string AccountGroup { get; set; } = "大号";

    public void Save() => Plugin.PluginInterface.SavePluginConfig(this);
}
