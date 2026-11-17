using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace MahjongAI_Assistant;

public sealed class TeamRoomClient : IDisposable
{
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(5) };
    private readonly string baseUrl;

    public TeamRoomClient(string url) => baseUrl = url.TrimEnd('/');

    public async Task<JsonDocument> CreateAsync(string name, string team)
    {
        var response = await http.PostAsJsonAsync($"{baseUrl}/v1/team-rooms", new
        {
            mode = "sandbox", name, team, consent = true
        });
        return await ReadResponse(response);
    }

    public async Task<JsonDocument> JoinAsync(string roomId, string inviteCode, string name, string team)
    {
        var response = await http.PostAsJsonAsync($"{baseUrl}/v1/team-rooms/{Uri.EscapeDataString(roomId)}/join", new
        {
            invite_code = inviteCode, name, team, consent = true
        });
        return await ReadResponse(response);
    }

    public async Task<JsonDocument> GetRoomAsync(string roomId, string token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"{baseUrl}/v1/team-rooms/{Uri.EscapeDataString(roomId)}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(request);
        return await ReadResponse(response);
    }

    public async Task<JsonDocument> SubmitSnapshotAsync(string roomId, string token, JsonElement snapshot)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post,
            $"{baseUrl}/v1/team-rooms/{Uri.EscapeDataString(roomId)}/snapshot")
        {
            Content = JsonContent.Create(new { snapshot })
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await http.SendAsync(request);
        return await ReadResponse(response);
    }

    private static async Task<JsonDocument> ReadResponse(HttpResponseMessage response)
    {
        var body = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException($"HTTP {(int)response.StatusCode}: {body}");
        return JsonDocument.Parse(body);
    }

    public void Dispose() => http.Dispose();
}
