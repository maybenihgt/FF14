using System.Numerics;
using Dalamud.Bindings.ImGui;
using Dalamud.Interface.Windowing;
using MahjongAI_Assistant.Engine;

namespace MahjongAI_Assistant.Windows;

public sealed class MainWindow : Window, IDisposable
{
    private readonly Plugin plugin;
    private string handInput = "123m 456p 789s 1112z";
    private string result = "输入自己当前可见的 13 张或 14 张手牌，然后点击分析。";
    private string error = string.Empty;
    private int[]? parsedHand;

    public MainWindow(Plugin plugin) : base("Mahjong AI Assistant")
    {
        this.plugin = plugin;
        SizeConstraints = new WindowSizeConstraints
        {
            MinimumSize = new Vector2(540, 440),
            MaximumSize = new Vector2(980, 820),
        };
    }

    public void Dispose() { }

    public override void Draw()
    {
        if (!ImGui.BeginTabBar("MahjongAIAssistantTabs")) return;
        if (ImGui.BeginTabItem("分析")) { DrawAnalyzer(); ImGui.EndTabItem(); }
        if (ImGui.BeginTabItem("账号")) { DrawAccounts(); ImGui.EndTabItem(); }
        if (ImGui.BeginTabItem("状态")) { DrawStatus(); ImGui.EndTabItem(); }
        if (ImGui.BeginTabItem("说明")) { DrawNotes(); ImGui.EndTabItem(); }
        ImGui.EndTabBar();
    }

    private void DrawAnalyzer()
    {
        ImGui.TextWrapped("轻量本地算法：标准型、七对子、国士无双向听数，以及有效牌/弃牌比较。");
        ImGui.TextDisabled("输入示例：123m 456p 789s 1112z（m=万、p=筒、s=索、z=字牌）。");
        ImGui.Separator();
        ImGui.Text("手牌（13 或 14 张）：");
        ImGui.SetNextItemWidth(-1);
        ImGui.InputText("##hand", ref handInput, 256);
        if (ImGui.Button("分析手牌")) Analyze();
        ImGui.SameLine();
        if (ImGui.Button("清空"))
        {
            handInput = string.Empty;
            result = "等待输入。";
            error = string.Empty;
            parsedHand = null;
        }

        if (!string.IsNullOrWhiteSpace(error))
            ImGui.TextColored(new Vector4(1f, 0.35f, 0.3f, 1f), error);

        ImGui.Separator();
        ImGui.TextWrapped(result);
        if (parsedHand is null) return;

        if (parsedHand.Sum() == 13)
        {
            var effective = ShantenCalculator.EffectiveTiles(parsedHand);
            ImGui.Spacing();
            ImGui.Text("有效牌（按输入手牌估算剩余数量）：");
            if (effective.Count == 0)
                ImGui.TextDisabled("没有找到能降低向听数的牌。");
            else
            {
                foreach (var item in effective)
                    ImGui.BulletText($"{TileHand.FormatTile(item.Tile)}：理论剩余 {item.Remaining} 张");
                ImGui.Text($"有效牌总数：{effective.Sum(x => x.Remaining)}");
            }
        }
        else
        {
            ImGui.Spacing();
            ImGui.Text("14 张手牌：弃牌比较");
            ImGui.TextDisabled("按弃牌后的向听数优先，再按理论有效牌数量排序。");
            foreach (var option in ShantenCalculator.DiscardOptions(parsedHand))
                ImGui.BulletText($"打 {TileHand.FormatTile(option.Discard)}：{option.Shanten} 向听；理论有效牌 {option.Ukeire} 张");
        }
    }

    private void DrawAccounts()
    {
        ImGui.Text("为当前运行此插件的客户端设置本地标签：");
        if (ImGui.Button("MAIN_A · 大号")) SetAccount("MAIN_A", "大号");
        ImGui.SameLine();
        if (ImGui.Button("MAIN_B · 大号")) SetAccount("MAIN_B", "大号");
        if (ImGui.Button("ALT_C · 小号")) SetAccount("ALT_C", "小号");
        ImGui.SameLine();
        if (ImGui.Button("ALT_D · 小号")) SetAccount("ALT_D", "小号");
        ImGui.Separator();
        ImGui.Text($"当前标签：{plugin.Configuration.AccountId}（{plugin.Configuration.AccountGroup}）");
        ImGui.TextDisabled("目前仅保存本机标签；尚未实现跨电脑同步。");
    }

    private void DrawStatus()
    {
        ImGui.Text("Mahjong AI Assistant 1.0");
        ImGui.Separator();
        ImGui.Text($"电脑：{Environment.MachineName}");
        ImGui.Text($"本地标签：{plugin.Configuration.AccountId}");
        ImGui.Text($"FFXIV 玩家状态：{(Plugin.PlayerState.IsLoaded ? "已登录" : "未登录")}");
        ImGui.Text("分析引擎：内置轻量算法（无需模型下载）");
        ImGui.Text("游戏数据读取：手动录入");
    }

    private void DrawNotes()
    {
        ImGui.TextWrapped("本插件不需要外部 AI 环境、授权服务器或模型文件。分析数据由玩家手动输入自己可见的手牌。");
        ImGui.Spacing();
        ImGui.TextWrapped("算法支持闭门日本立直麻将的标准型、七对子、国士无双向听数，以及理论有效牌/弃牌比较。理论剩余牌数只根据输入手牌扣除，不包含牌河、副露或其他可见牌。");
        ImGui.Spacing();
        ImGui.TextWrapped("副露、赤宝牌、役种、点数、场况和 FF14 多玛麻将特殊规则尚未实现。请勿将结果视为完整牌局决策，也不提供自动出牌或多账号操纵牌局功能。");
    }

    private void Analyze()
    {
        try
        {
            parsedHand = TileHand.Parse(handInput);
            if (parsedHand.Sum() == 13)
            {
                int shanten = ShantenCalculator.Calculate(parsedHand);
                result = shanten == 0 ? "当前 0 向听（听牌）。" : $"当前 {shanten} 向听。";
            }
            else
            {
                int best = ShantenCalculator.DiscardOptions(parsedHand).First().Shanten;
                result = $"14 张手牌；最佳弃牌后可达到 {best} 向听。";
            }
            error = string.Empty;
        }
        catch (Exception ex)
        {
            parsedHand = null;
            error = ex.Message;
            result = string.Empty;
        }
    }

    private void SetAccount(string id, string group)
    {
        plugin.Configuration.AccountId = id;
        plugin.Configuration.AccountGroup = group;
        plugin.Configuration.Save();
    }
}
