namespace MahjongAI_Assistant.Engine;

/// <summary>Parser for closed riichi hands, e.g. 123m 456p 789s 1122z.</summary>
public static class TileHand
{
    public static readonly string[] TileNames =
    [
        "1m","2m","3m","4m","5m","6m","7m","8m","9m",
        "1p","2p","3p","4p","5p","6p","7p","8p","9p",
        "1s","2s","3s","4s","5s","6s","7s","8s","9s",
        "東","南","西","北","白","發","中"
    ];

    public static int[] Parse(string input)
    {
        if (string.IsNullOrWhiteSpace(input))
            throw new FormatException("请输入手牌，例如：123m 456p 789s 1122z");

        var counts = new int[34];
        var digits = new List<int>();
        foreach (char raw in input.Replace(" ", "").Replace(",", "").Replace("，", "").Replace("、", ""))
        {
            char c = char.ToLowerInvariant(raw);
            if (c is >= '0' and <= '9')
            {
                digits.Add(c - '0');
                continue;
            }

            int suit = c switch { 'm' => 0, 'p' => 1, 's' => 2, 'z' => 3, _ => -1 };
            if (suit < 0) throw new FormatException($"无法识别字符：{raw}。花色请使用 m/p/s/z。");
            if (digits.Count == 0) throw new FormatException($"花色 {raw} 前没有数字。");

            foreach (int digit in digits)
            {
                int max = suit == 3 ? 7 : 9;
                if (digit < 1 || digit > max)
                    throw new FormatException($"{digit}{raw} 不是有效牌。");
                int index = suit * 9 + digit - 1;
                if (++counts[index] > 4)
                    throw new FormatException($"{digit}{raw} 超过四张。");
            }
            digits.Clear();
        }

        if (digits.Count != 0) throw new FormatException("末尾数字缺少花色 m/p/s/z。");
        int total = counts.Sum();
        if (total is not (13 or 14))
            throw new FormatException($"请输入 13 或 14 张牌；当前识别到 {total} 张。");
        return counts;
    }

    public static string FormatTile(int index) => TileNames[index];
}
