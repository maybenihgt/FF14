namespace MahjongAI_Assistant.Engine;

/// <summary>
/// Lightweight closed-hand riichi shanten / ukeire calculator.
/// Remaining counts are theoretical (4 minus copies in the entered hand),
/// not a live visible-tile count.
/// </summary>
public static class ShantenCalculator
{
    public static int Calculate(int[] source)
    {
        Validate(source, allowFourteen: true);
        if (source.Sum() == 13) return CalculateThirteen(source);

        int best = int.MaxValue;
        for (int i = 0; i < 34; i++)
        {
            if (source[i] == 0) continue;
            source[i]--;
            best = Math.Min(best, CalculateThirteen(source));
            source[i]++;
        }
        return best;
    }

    public static List<(int Tile, int Remaining)> EffectiveTiles(int[] hand)
    {
        Validate(hand, allowFourteen: false);
        int current = CalculateThirteen(hand);
        var result = new List<(int Tile, int Remaining)>();
        for (int i = 0; i < 34; i++)
        {
            if (hand[i] >= 4) continue;
            hand[i]++;
            int next = CalculateThirteen(hand);
            hand[i]--;
            if (next < current) result.Add((i, 4 - hand[i]));
        }
        return result;
    }

    public static List<(int Discard, int Shanten, int Ukeire)> DiscardOptions(int[] hand)
    {
        Validate(hand, allowFourteen: true);
        if (hand.Sum() != 14) throw new ArgumentException("弃牌比较需要 14 张手牌。");
        var options = new List<(int Discard, int Shanten, int Ukeire)>();
        for (int i = 0; i < 34; i++)
        {
            if (hand[i] == 0) continue;
            hand[i]--;
            int shanten = CalculateThirteen(hand);
            int ukeire = EffectiveTiles(hand).Sum(x => x.Remaining);
            hand[i]++;
            options.Add((i, shanten, ukeire));
        }
        return options.OrderBy(x => x.Shanten).ThenByDescending(x => x.Ukeire).ToList();
    }

    private static int CalculateThirteen(int[] source)
    {
        int[] counts = (int[])source.Clone();
        var memo = new Dictionary<string, int>();
        int standard = StandardShanten(counts, 0, 0, 0, memo);
        int chiitoi = ChiitoitsuShanten(source);
        int kokushi = KokushiShanten(source);
        return Math.Min(standard, Math.Min(chiitoi, kokushi));
    }

    private static int StandardShanten(int[] c, int melds, int taatsu, int pair, Dictionary<string, int> memo)
    {
        string key = string.Join("", c) + $"|{melds}|{taatsu}|{pair}";
        if (memo.TryGetValue(key, out int cached)) return cached;

        int first = Array.FindIndex(c, x => x > 0);
        if (first < 0)
        {
            int usefulTaatsu = Math.Min(taatsu, 4 - melds);
            int terminal = 8 - 2 * melds - usefulTaatsu - pair;
            memo[key] = terminal;
            return terminal;
        }

        int best = 8;
        c[first]--;
        best = Math.Min(best, StandardShanten(c, melds, taatsu, pair, memo));
        c[first]++;

        if (melds < 4 && c[first] >= 3)
        {
            c[first] -= 3;
            best = Math.Min(best, StandardShanten(c, melds + 1, taatsu, pair, memo));
            c[first] += 3;
        }

        if (melds < 4 && first < 27 && first % 9 <= 6 && c[first + 1] > 0 && c[first + 2] > 0)
        {
            c[first]--; c[first + 1]--; c[first + 2]--;
            best = Math.Min(best, StandardShanten(c, melds + 1, taatsu, pair, memo));
            c[first]++; c[first + 1]++; c[first + 2]++;
        }

        if (c[first] >= 2)
        {
            c[first] -= 2;
            if (pair == 0) best = Math.Min(best, StandardShanten(c, melds, taatsu, 1, pair == 0 ? memo : memo));
            else if (taatsu < 4) best = Math.Min(best, StandardShanten(c, melds, taatsu + 1, pair, memo));
            c[first] += 2;
        }

        if (taatsu < 4 && first < 27 && first % 9 <= 7 && c[first + 1] > 0)
        {
            c[first]--; c[first + 1]--;
            best = Math.Min(best, StandardShanten(c, melds, taatsu + 1, pair, memo));
            c[first]++; c[first + 1]++;
        }
        if (taatsu < 4 && first < 27 && first % 9 <= 6 && c[first + 2] > 0)
        {
            c[first]--; c[first + 2]--;
            best = Math.Min(best, StandardShanten(c, melds, taatsu + 1, pair, memo));
            c[first]++; c[first + 2]++;
        }

        memo[key] = best;
        return best;
    }

    private static int ChiitoitsuShanten(int[] c)
    {
        int pairs = c.Count(x => x >= 2);
        int distinct = c.Count(x => x > 0);
        return 6 - pairs + Math.Max(0, 7 - distinct);
    }

    private static int KokushiShanten(int[] c)
    {
        ReadOnlySpan<int> terminals = [0, 8, 9, 17, 18, 26, 27, 28, 29, 30, 31, 32, 33];
        int unique = 0;
        bool pair = false;
        foreach (int i in terminals)
        {
            if (c[i] > 0) unique++;
            if (c[i] > 1) pair = true;
        }
        return 13 - unique - (pair ? 1 : 0);
    }

    private static void Validate(int[] hand, bool allowFourteen)
    {
        if (hand is null || hand.Length != 34) throw new ArgumentException("牌数组必须包含 34 种牌。");
        if (hand.Any(x => x is < 0 or > 4)) throw new ArgumentException("每种牌数量必须在 0 到 4 之间。");
        int total = hand.Sum();
        if (total != 13 && (!allowFourteen || total != 14))
            throw new ArgumentException(allowFourteen ? "仅支持 13 或 14 张手牌。" : "有效牌计算需要 13 张手牌。");
    }
}
