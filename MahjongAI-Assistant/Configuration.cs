using System;
using Dalamud.Configuration;

namespace MahjongAI_Assistant;

[Serializable]
public sealed class Configuration : IPluginConfiguration
{
    public int Version { get; set; } = 2;
    public string AccountId { get; set; } = "MAIN_A";
    public string AccountGroup { get; set; } = "大号";
    public string MortalBridgeUrl { get; set; } = "http://127.0.0.1:8765";
    public string TeamRoomUrl { get; set; } = "http://127.0.0.1:8770";
    public string TeamRoomId { get; set; } = string.Empty;
    public string TeamRoomInviteCode { get; set; } = string.Empty;
    public string TeamRoomToken { get; set; } = string.Empty;
    public string TeamRoomTeam { get; set; } = "A";

    public void Save() => Plugin.PluginInterface.SavePluginConfig(this);
}
