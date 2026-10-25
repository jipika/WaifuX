//
//  WaifuX Steam service.
//  The SteamKit2 authentication/session flow is adapted from MirageWallpaper.
//
//  Copyright © 2026 王孝慈. All rights reserved.
//

using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using SteamKit2;
using SteamKit2.Authentication;
using SteamKit2.CDN;
using SteamKit2.Internal;
using SteamKit2.WebUI.Internal;

namespace WaifuXSteamService;

internal sealed class SteamSession : IAsyncDisposable
{
    public const uint AppId = 431960;
    private const uint WorkshopSubscriptionListType = 1;

    private readonly ProtocolWriter writer;
    private readonly SteamConfiguration configuration;
    private readonly SteamClient client;
    private readonly CallbackManager callbacks;
    private readonly SteamUser user;
    private readonly SteamApps apps;
    private readonly SteamContent content;
    private readonly PublishedFile publishedFiles;
    private readonly Community community;
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim authGate = new(1, 1);
    private readonly SemaphoreSlim appInfoGate = new(1, 1);
    private readonly SemaphoreSlim favoriteGate = new(1, 1);
    private readonly SemaphoreSlim contentServerGate = new(1, 1);
    private readonly object stateGate = new();
    private readonly ConcurrentDictionary<(uint DepotId, string Host), SteamContent.CDNAuthToken> cdnTokens = new();
    private readonly ConcurrentDictionary<string, int> contentServerFailures = new(StringComparer.OrdinalIgnoreCase);
    private readonly Task callbackLoop;
    private TaskCompletionSource<bool>? connectedSource;
    private TaskCompletionSource<bool>? resetConnectionSource;
    private TaskCompletionSource<SteamUser.LoggedOnCallback>? loggedOnSource;
    private InteractiveAuthenticator? authenticator;
    private CancellationTokenSource? authCancellation;
    private SteamApps.PICSProductInfoCallback.PICSProductInfo? appInfo;
    private string refreshToken = "";
    private string accessToken = "";
    private string reconnectAccountName = "";
    private uint loginId;
    private Server[] contentServers = [];
    private DateTime contentServerExpiration = DateTime.MinValue;
    private DateTime contentServerRefreshNotBefore = DateTime.MinValue;
    private int contentServerCursor;
    private TaskCompletionSource<bool> onlineSource = NewOnlineSource();
    private CancellationTokenSource? recoveryCancellation;
    private Task? recoveryTask;
    private bool shuttingDown;
    private bool serverListPrepared;

    public bool IsLoggedIn { get; private set; }
    public string AccountName { get; private set; } = "";
    public string SteamId { get; private set; } = "";
    public SteamClient Client => client;
    public SteamApps Apps => apps;
    public SteamContent Content => content;
    public PublishedFile PublishedFiles => publishedFiles;

    public SteamSession(ProtocolWriter writer)
    {
        this.writer = writer;
        var configuration = SteamConfiguration.Create(builder => builder
            .WithConnectionTimeout(TimeSpan.FromSeconds(6))
            .WithHttpClientFactory(_ =>
        {
            var sockets = new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(10),
                ConnectTimeout = TimeSpan.FromSeconds(20)
            };
            var httpClient = new HttpClient(new CountingHandler(sockets), true)
            {
                Timeout = Timeout.InfiniteTimeSpan
            };
            var version = typeof(SteamClient).Assembly.GetName().Version?.ToString(3) ?? "3.4.0";
            httpClient.DefaultRequestHeaders.UserAgent.ParseAdd($"SteamKit/{version}");
            return httpClient;
        }));
        this.configuration = configuration;
        client = new SteamClient(configuration);
        callbacks = new CallbackManager(client);
        user = client.GetHandler<SteamUser>()!;
        apps = client.GetHandler<SteamApps>()!;
        content = client.GetHandler<SteamContent>()!;
        var unifiedMessages = client.GetHandler<SteamUnifiedMessages>()!;
        publishedFiles = unifiedMessages.CreateService<PublishedFile>();
        community = unifiedMessages.CreateService<Community>();
        callbacks.Subscribe<SteamClient.ConnectedCallback>(OnConnected);
        callbacks.Subscribe<SteamClient.DisconnectedCallback>(OnDisconnected);
        callbacks.Subscribe<SteamUser.LoggedOnCallback>(OnLoggedOn);
        callbacks.Subscribe<SteamUser.LoggedOffCallback>(OnLoggedOff);
        callbackLoop = RunCallbacksAsync();
    }

    public async Task LoginWithRefreshTokenAsync(string username, string refreshToken, uint loginId, CancellationToken cancellationToken)
    {
        CancelRecovery();
        var effectiveLoginId = NormalizeLoginId(loginId);
        await authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            writer.AuthState("connecting", username);
            await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
            await LogOnAsync(username, refreshToken, effectiveLoginId, cancellationToken).ConfigureAwait(false);
            this.refreshToken = refreshToken;
            accessToken = "";
            AccountName = username;
            reconnectAccountName = username;
            this.loginId = effectiveLoginId;
            MarkOnline();
            writer.AuthState("loggedIn", username, steamId: SteamId);
        }
        finally
        {
            authGate.Release();
        }
    }

    public async Task LoginWithPasswordAsync(string username, string password, string? guardData, string? guardCode, uint loginId, CancellationToken cancellationToken)
    {
        CancelRecovery();
        var effectiveLoginId = NormalizeLoginId(loginId);
        await authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            CancelAuthentication();
            authCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            var loginAuthenticator = new InteractiveAuthenticator(writer);
            loginAuthenticator.SetInitialCode(guardCode);
            authenticator = loginAuthenticator;
            writer.AuthState("connecting", username);
            await EnsureConnectedAsync(authCancellation.Token).ConfigureAwait(false);
            writer.AuthState("authenticating", username);
            var session = await client.Authentication.BeginAuthSessionViaCredentialsAsync(new AuthSessionDetails
                {
                    Username = username,
                    Password = password,
                    IsPersistentSession = true,
                    GuardData = guardData,
                    Authenticator = loginAuthenticator,
                    DeviceFriendlyName = "WaifuX for macOS"
                })
                .WaitAsync(authCancellation.Token)
                .ConfigureAwait(false);
            var result = await PollCredentialsResultAsync(session, loginAuthenticator, authCancellation.Token).ConfigureAwait(false);
            await LogOnAsync(result.AccountName, result.RefreshToken, effectiveLoginId, authCancellation.Token).ConfigureAwait(false);
            refreshToken = result.RefreshToken;
            accessToken = result.AccessToken;
            AccountName = result.AccountName;
            reconnectAccountName = result.AccountName;
            this.loginId = effectiveLoginId;
            MarkOnline();
            writer.AuthState("loggedIn", result.AccountName, refreshToken: result.RefreshToken, guardData: result.NewGuardData ?? guardData, steamId: SteamId);
        }
        finally
        {
            authenticator = null;
            authCancellation?.Dispose();
            authCancellation = null;
            authGate.Release();
        }
    }

    public async Task LoginWithQrAsync(uint loginId, CancellationToken cancellationToken)
    {
        CancelRecovery();
        var effectiveLoginId = NormalizeLoginId(loginId);
        await authGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            CancelAuthentication();
            authCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, lifetime.Token);
            writer.AuthState("connecting");
            await EnsureConnectedAsync(authCancellation.Token).ConfigureAwait(false);
            var session = await client.Authentication.BeginAuthSessionViaQRAsync(new AuthSessionDetails
                {
                    IsPersistentSession = true,
                    DeviceFriendlyName = "WaifuX for macOS"
                })
                .WaitAsync(authCancellation.Token)
                .ConfigureAwait(false);
            session.ChallengeURLChanged = () => writer.AuthState("qr", challengeUrl: session.ChallengeURL);
            writer.AuthState("qr", challengeUrl: session.ChallengeURL);
            var result = await session.PollingWaitForResultAsync(authCancellation.Token).ConfigureAwait(false);
            writer.AuthState("authenticating", result.AccountName);
            await LogOnAsync(result.AccountName, result.RefreshToken, effectiveLoginId, authCancellation.Token).ConfigureAwait(false);
            refreshToken = result.RefreshToken;
            accessToken = result.AccessToken;
            AccountName = result.AccountName;
            reconnectAccountName = result.AccountName;
            this.loginId = effectiveLoginId;
            MarkOnline();
            writer.AuthState("loggedIn", result.AccountName, refreshToken: result.RefreshToken, guardData: result.NewGuardData, steamId: SteamId);
        }
        finally
        {
            authCancellation?.Dispose();
            authCancellation = null;
            authGate.Release();
        }
    }

    public bool SubmitChallenge(string code)
    {
        return authenticator?.Submit(code) == true;
    }

    private static async Task<AuthPollResult> PollCredentialsResultAsync(CredentialsAuthSession session, InteractiveAuthenticator loginAuthenticator, CancellationToken cancellationToken)
    {
        try
        {
            return await session.PollingWaitForResultAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (AsyncJobFailedException) when (loginAuthenticator.IsWaitingForDeviceConfirmation)
        {
            var failures = 1;
            var interval = session.PollingInterval < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : session.PollingInterval;
            while (true)
            {
                await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
                try
                {
                    var result = await session.PollAuthSessionStatusAsync().WaitAsync(cancellationToken).ConfigureAwait(false);
                    failures = 0;
                    if (result != null) return result;
                }
                catch (AsyncJobFailedException) when (failures < 5)
                {
                    failures += 1;
                }
                catch (AsyncJobFailedException)
                {
                    throw new ServiceException("AUTH_SERVICE_TEMPORARY", "Steam authentication service did not return the confirmed session.");
                }
            }
        }
    }

    public void CancelAuthentication()
    {
        authenticator?.Cancel();
        try { authCancellation?.Cancel(); } catch (ObjectDisposedException) { } catch (AggregateException) { }
    }

    public async Task ResetConnectionAsync()
    {
        var source = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        resetConnectionSource = source;
        connectedSource = null;
        loggedOnSource = null;
        client.Disconnect();
        try { await source.Task.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } catch (TimeoutException) { }
        if (ReferenceEquals(resetConnectionSource, source)) resetConnectionSource = null;
    }

    public async Task<SteamApps.PICSProductInfoCallback.PICSProductInfo> GetAppInfoAsync(CancellationToken cancellationToken)
    {
        if (appInfo != null) return appInfo;
        await appInfoGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (appInfo != null) return appInfo;
            cancellationToken.ThrowIfCancellationRequested();
            var tokens = await apps.PICSGetAccessTokens([AppId], []).ToTask().WaitAsync(cancellationToken).ConfigureAwait(false);
            var request = new SteamApps.PICSRequest(AppId);
            if (tokens.AppTokens.TryGetValue(AppId, out var token)) request.AccessToken = token;
            cancellationToken.ThrowIfCancellationRequested();
            var response = await apps.PICSGetProductInfo([request], []).ToTask().WaitAsync(cancellationToken).ConfigureAwait(false);
            var results = response?.Results ?? throw new ServiceException("APP_INFO_UNAVAILABLE", "Wallpaper Engine app information is unavailable for this account.");
            foreach (var result in results)
            {
                if (result.Apps.TryGetValue(AppId, out var info))
                {
                    appInfo = info;
                    return info;
                }
            }
            throw new ServiceException("APP_INFO_UNAVAILABLE", "Wallpaper Engine app information is unavailable for this account.");
        }
        finally
        {
            appInfoGate.Release();
        }
    }

    public async Task<(Server Server, string? Token)> GetDownloadServerAsync(uint depotId, int offset, CancellationToken cancellationToken)
    {
        var servers = await GetContentServersAsync(cancellationToken).ConfigureAwait(false);
        var eligible = servers
            .OrderBy(server => contentServerFailures.TryGetValue(server.Host!, out var failures) ? failures : 0)
            .ThenBy(server => server.WeightedLoad)
            .ToArray();
        if (eligible.Length == 0) throw new ServiceException("NO_CONTENT_SERVER", "Steam returned no eligible content server.");
        var selection = unchecked((uint)(Interlocked.Increment(ref contentServerCursor) + offset));
        var selected = eligible[selection % (uint)eligible.Length];
        var host = selected.Host!;
        var key = (depotId, host);
        if (!cdnTokens.TryGetValue(key, out var auth) || auth.Expiration <= DateTime.UtcNow.AddMinutes(1))
        {
            var result = await content.GetCDNAuthToken(AppId, depotId, host).WaitAsync(cancellationToken).ConfigureAwait(false);
            if (result.Result == EResult.OK)
            {
                auth = result;
                cdnTokens[key] = result;
            }
            else
            {
                return (selected, null);
            }
        }
        return (selected, auth.Token);
    }

    public void ReportDownloadServerFailure(uint depotId, string? host)
    {
        if (string.IsNullOrWhiteSpace(host)) return;
        cdnTokens.TryRemove((depotId, host), out _);
        var failures = contentServerFailures.AddOrUpdate(host, 1, static (_, value) => value + 1);
        if (failures < 2 || DateTime.UtcNow < contentServerRefreshNotBefore) return;
        contentServerRefreshNotBefore = DateTime.UtcNow.AddSeconds(10);
        contentServerExpiration = DateTime.MinValue;
    }

    public void ReportDownloadServerSuccess(string? host)
    {
        if (!string.IsNullOrWhiteSpace(host)) contentServerFailures.TryRemove(host, out _);
    }

    public async Task WaitForOnlineAsync(CancellationToken cancellationToken)
    {
        Task onlineTask;
        lock (stateGate)
        {
            if (IsLoggedIn) return;
            onlineTask = onlineSource.Task;
        }
        await onlineTask.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<Server[]> GetContentServersAsync(CancellationToken cancellationToken)
    {
        var now = DateTime.UtcNow;
        var cached = contentServers;
        if (cached.Length > 0 && now < contentServerExpiration) return cached;

        await contentServerGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            now = DateTime.UtcNow;
            cached = contentServers;
            if (cached.Length > 0 && now < contentServerExpiration) return cached;
            try
            {
                var servers = await content.GetServersForSteamPipe().WaitAsync(cancellationToken).ConfigureAwait(false);
                var eligible = servers
                    .Where(server => !string.IsNullOrWhiteSpace(server.Host) &&
                        (server.AllowedAppIds.Length == 0 || server.AllowedAppIds.Contains(AppId)) &&
                        (server.Type == "CDN" || server.Type == "SteamCache"))
                    .ToArray();
                if (eligible.Length == 0) throw new ServiceException("NO_CONTENT_SERVER", "Steam returned no eligible content server.");
                contentServers = eligible;
                contentServerExpiration = now.AddMinutes(2);
                contentServerFailures.Clear();
                return eligible;
            }
            catch when (cached.Length > 0)
            {
                contentServerExpiration = now.AddSeconds(15);
                return cached;
            }
        }
        finally
        {
            contentServerGate.Release();
        }
    }

    public async Task<SubscriptionPage> GetSubscriptionsAsync(int startIndex, CancellationToken cancellationToken)
    {
        const int pageSize = 50;
        if (!ulong.TryParse(SteamId, out var steamId))
        {
            throw new ServiceException("NOT_AUTHENTICATED", "The Steam session has no valid Steam ID.");
        }
        var normalizedStart = Math.Max(0, startIndex);
        var request = new CPublishedFile_GetUserFiles_Request
        {
            steamid = steamId,
            appid = AppId,
            page = checked((uint)(normalizedStart / pageSize + 1)),
            numperpage = pageSize,
            type = "mysubscriptions"
        };
        var response = await publishedFiles.GetUserFiles(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "SUBSCRIPTIONS_UNAVAILABLE");
        var files = response.Body.publishedfiledetails
            .Where(file => file.consumer_appid == AppId)
            .Select(file => new SubscribedFile(
                file.publishedfileid,
                file.time_subscribed,
                file.time_updated,
                file.hcontent_file,
                file.file_size,
                file.consumer_appid))
            .ToArray();
        return new SubscriptionPage(
            checked((int)response.Body.total),
            normalizedStart,
            files);
    }

    public async Task<FavoritePage> GetFavoritesAsync(int startIndex, CancellationToken cancellationToken)
    {
        const int pageSize = 50;
        if (!ulong.TryParse(SteamId, out var steamId))
        {
            throw new ServiceException("NOT_AUTHENTICATED", "The Steam session has no valid Steam ID.");
        }
        var normalizedStart = Math.Max(0, startIndex);
        var request = new CPublishedFile_GetUserFiles_Request
        {
            steamid = steamId,
            appid = AppId,
            page = checked((uint)(normalizedStart / pageSize + 1)),
            numperpage = pageSize,
            type = "myfavorites",
            ids_only = true
        };
        var response = await publishedFiles.GetUserFiles(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "FAVORITES_UNAVAILABLE");
        var ids = response.Body.publishedfiledetails
            .Where(file => file.consumer_appid == 0 || file.consumer_appid == AppId)
            .Select(file => file.publishedfileid)
            .Where(id => id != 0)
            .ToArray();
        return new FavoritePage(
            checked((int)response.Body.total),
            normalizedStart,
            normalizedStart + pageSize,
            ids);
    }

    public async Task SetFavoriteAsync(ulong workshopId, bool favorite, CancellationToken cancellationToken)
    {
        await favoriteGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var token = await GetCommunityAccessTokenAsync(attempt > 0, cancellationToken).ConfigureAwait(false);
                var sessionId = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(12));
                var cookies = new CookieContainer();
                cookies.Add(new Cookie("sessionid", sessionId, "/", ".steamcommunity.com"));
                cookies.Add(new Cookie("steamLoginSecure", $"{SteamId}||{token}", "/", ".steamcommunity.com"));
                using var handler = new HttpClientHandler
                {
                    CookieContainer = cookies,
                    AllowAutoRedirect = true
                };
                using var http = new HttpClient(handler)
                {
                    Timeout = TimeSpan.FromSeconds(30)
                };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("Mirage Wallpaper/1.0");
                var endpoint = favorite ? "favorite" : "unfavorite";
                using var request = new HttpRequestMessage(
                    HttpMethod.Post,
                    $"https://steamcommunity.com/sharedfiles/{endpoint}");
                request.Headers.Referrer = new Uri(
                    $"https://steamcommunity.com/sharedfiles/filedetails/?id={workshopId}");
                request.Content = new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["id"] = workshopId.ToString(),
                    ["appid"] = AppId.ToString(),
                    ["sessionid"] = sessionId
                });
                using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
                if (response.IsSuccessStatusCode &&
                    await WaitForFavoriteStateAsync(workshopId, favorite, cancellationToken).ConfigureAwait(false))
                {
                    return;
                }
                accessToken = "";
            }
            throw new ServiceException(
                favorite ? "FAVORITE_ADD_FAILED" : "FAVORITE_REMOVE_FAILED",
                "Steam did not confirm the requested favorite state.");
        }
        finally
        {
            favoriteGate.Release();
        }
    }

    private async Task<string> GetCommunityAccessTokenAsync(bool forceRefresh, CancellationToken cancellationToken)
    {
        if (!forceRefresh && !string.IsNullOrWhiteSpace(accessToken)) return accessToken;
        if (!ulong.TryParse(SteamId, out var steamId) || string.IsNullOrWhiteSpace(refreshToken))
        {
            throw new ServiceException("NOT_AUTHENTICATED", "The Steam session has no reusable authentication token.");
        }
        var result = await client.Authentication
            .GenerateAccessTokenForAppAsync(new SteamID(steamId), refreshToken)
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(result.AccessToken))
        {
            throw new ServiceException("FAVORITE_SESSION_FAILED", "Steam did not issue a community access token.");
        }
        accessToken = result.AccessToken;
        return accessToken;
    }

    private async Task<bool> WaitForFavoriteStateAsync(ulong workshopId, bool favorite, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (await IsFavoriteAsync(workshopId, cancellationToken).ConfigureAwait(false) == favorite) return true;
            await Task.Delay(500, cancellationToken).ConfigureAwait(false);
        }
        return await IsFavoriteAsync(workshopId, cancellationToken).ConfigureAwait(false) == favorite;
    }

    private async Task<bool> IsFavoriteAsync(ulong workshopId, CancellationToken cancellationToken)
    {
        var startIndex = 0;
        while (true)
        {
            var page = await GetFavoritesAsync(startIndex, cancellationToken).ConfigureAwait(false);
            if (page.PublishedFileIds.Contains(workshopId)) return true;
            if (page.NextStartIndex >= page.TotalResults) return false;
            startIndex = page.NextStartIndex;
        }
    }

    public async Task<IReadOnlyDictionary<ulong, bool>> GetSubscriptionStatesAsync(IEnumerable<ulong> workshopIds, CancellationToken cancellationToken)
    {
        var states = new Dictionary<ulong, bool>();
        foreach (var chunk in workshopIds.Distinct().Chunk(100))
        {
            var request = new CPublishedFile_AreFilesInSubscriptionList_Request { appid = AppId, listtype = WorkshopSubscriptionListType };
            request.publishedfileids.AddRange(chunk);
            var response = await publishedFiles.AreFilesInSubscriptionList(request)
                .ToTask()
                .WaitAsync(cancellationToken)
                .ConfigureAwait(false);
            EnsureSuccess(response.Result, "SUBSCRIPTION_STATUS_UNAVAILABLE");
            foreach (var item in response.Body.files)
            {
                states[item.publishedfileid] = item.inlist;
            }
        }
        return states;
    }

    public async Task SubscribeAsync(ulong workshopId, CancellationToken cancellationToken)
    {
        var request = new CPublishedFile_Subscribe_Request
        {
            publishedfileid = workshopId,
            list_type = WorkshopSubscriptionListType,
            appid = checked((int)AppId),
            notify_client = true,
            include_dependencies = true
        };
        var response = await publishedFiles.Subscribe(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "SUBSCRIBE_FAILED");
    }

    public async Task UnsubscribeAsync(ulong workshopId, CancellationToken cancellationToken)
    {
        var request = new CPublishedFile_Unsubscribe_Request
        {
            publishedfileid = workshopId,
            list_type = WorkshopSubscriptionListType,
            appid = checked((int)AppId),
            notify_client = true
        };
        var response = await publishedFiles.Unsubscribe(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "UNSUBSCRIBE_FAILED");
    }

    public async Task<CommentPage> GetCommentsAsync(ulong workshopId, ulong creatorSteamId, int startIndex, int count, CancellationToken cancellationToken)
    {
        var request = new CCommunity_GetCommentThread_Request
        {
            steamid = creatorSteamId,
            comment_thread_type = (int)ECommentThreadType.k_ECommentThreadTypePublishedFile_Public,
            gidfeature = workshopId,
            start = Math.Max(0, startIndex),
            count = Math.Clamp(count, 1, 50),
            upvoters = 3,
            oldest_first = false
        };
        var response = await community.GetCommentThread(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "COMMENTS_UNAVAILABLE");
        var receivedComments = response.Body.comments;
        var comments = receivedComments
            .Where(comment => !comment.deleted)
            .Select(comment => new SteamComment(
                comment.gidcomment,
                comment.steamid,
                comment.timestamp,
                comment.text,
                comment.upvotes,
                comment.hidden || comment.hidden_by_user))
            .ToArray();
        return new CommentPage(
            response.Body.total_count,
            response.Body.can_post,
            startIndex + receivedComments.Count,
            comments);
    }

    public async Task<ulong> PostCommentAsync(ulong workshopId, ulong creatorSteamId, string text, CancellationToken cancellationToken)
    {
        var request = new CCommunity_PostCommentToThread_Request
        {
            steamid = creatorSteamId,
            comment_thread_type = (int)ECommentThreadType.k_ECommentThreadTypePublishedFile_Public,
            gidfeature = workshopId,
            text = text,
            suppress_notifications = false
        };
        var response = await community.PostCommentToThread(request)
            .ToTask()
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        EnsureSuccess(response.Result, "COMMENT_POST_FAILED");
        return response.Body.gidcomment;
    }

    public void Logout()
    {
        CancelAuthentication();
        CancelRecovery();
        IsLoggedIn = false;
        AccountName = "";
        SteamId = "";
        refreshToken = "";
        accessToken = "";
        reconnectAccountName = "";
        loginId = 0;
        appInfo = null;
        cdnTokens.Clear();
        contentServers = [];
        contentServerFailures.Clear();
        MarkOffline();
        if (client.IsConnected) user.LogOff();
        writer.AuthState("loggedOut");
    }

    private static TaskCompletionSource<bool> NewOnlineSource()
    {
        return new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private static uint NormalizeLoginId(uint value)
    {
        return value == 0 ? (uint)RandomNumberGenerator.GetInt32(1, int.MaxValue) : value;
    }

    private void MarkOnline()
    {
        lock (stateGate) onlineSource.TrySetResult(true);
    }

    private void MarkOffline()
    {
        lock (stateGate)
        {
            if (onlineSource.Task.IsCompleted) onlineSource = NewOnlineSource();
        }
    }

    private void CancelRecovery()
    {
        lock (stateGate) recoveryCancellation?.Cancel();
    }

    private void StartRecovery(string message)
    {
        string username;
        string token;
        uint currentLoginId;
        CancellationTokenSource cancellation;
        lock (stateGate)
        {
            if (shuttingDown || recoveryTask is { IsCompleted: false }) return;
            username = reconnectAccountName;
            token = refreshToken;
            currentLoginId = loginId;
            if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(token))
            {
                writer.AuthState("loggedOut", message: message, errorCode: "CONNECTION_LOST");
                return;
            }
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            recoveryCancellation = cancellation;
            recoveryTask = Task.Run(() => RecoverAsync(username, token, NormalizeLoginId(currentLoginId), cancellation));
        }
    }

    private async Task RecoverAsync(string username, string token, uint currentLoginId, CancellationTokenSource cancellation)
    {
        var attempt = 0;
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                attempt += 1;
                writer.AuthState("reconnecting", username, message: "Steam connection is recovering.", errorCode: "CONNECTION_LOST");
                try
                {
                    await authGate.WaitAsync(cancellation.Token).ConfigureAwait(false);
                    try
                    {
                        if (client.IsConnected) await ResetConnectionAsync().ConfigureAwait(false);
                        await EnsureConnectedAsync(cancellation.Token).ConfigureAwait(false);
                        await LogOnAsync(username, token, currentLoginId, cancellation.Token).ConfigureAwait(false);
                    }
                    finally
                    {
                        authGate.Release();
                    }

                    refreshToken = token;
                    accessToken = "";
                    AccountName = username;
                    reconnectAccountName = username;
                    loginId = currentLoginId;
                    MarkOnline();
                    writer.AuthState("loggedIn", username, steamId: SteamId);
                    return;
                }
                catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
                catch (Exception error) when (IsTerminalAuthenticationFailure(error))
                {
                    MarkOffline();
                    writer.AuthState("loggedOut", username, message: error.Message, errorCode: "AUTH_FAILED");
                    return;
                }
                catch
                {
                    var seconds = Math.Min(30, 1 << Math.Min(attempt - 1, 5));
                    var jitter = Random.Shared.NextDouble() * 0.4;
                    await Task.Delay(TimeSpan.FromSeconds(seconds + jitter), cancellation.Token).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            lock (stateGate)
            {
                if (ReferenceEquals(recoveryCancellation, cancellation))
                {
                    recoveryCancellation = null;
                    recoveryTask = null;
                }
            }
            cancellation.Dispose();
        }
    }

    private static bool IsTerminalAuthenticationFailure(Exception error)
    {
        while (error.InnerException != null && error is AggregateException or IOException)
        {
            error = error.InnerException;
        }
        return error is ServiceException { Code: "AUTH_FAILED" };
    }

    /// <summary>
    /// 按「443 端口优先」重排 CM 候选。
    /// Steam 的 ISteamDirectory/GetCMListForConnect 会把大量 27015-27025 端点排在
    /// 443 前面（香港 cell 下前 39 条全是 270xx），而 SteamKit2 的
    /// SmartCMServerList.GetNextServerCandidate 严格按列表顺序取候选，失败后
    /// 逐个 TryMark(Bad) 再取下一个 —— 代理环境下 270xx 抖动，登录就被拖成
    /// 「尝试多个 270xx 端口并超时」。官方客户端固定走 443 + WebSocket，
    /// 这里对齐同样的行为：把 443 提到最前，其余保持原序作为兜底。
    /// </summary>
    private async Task PrepareServerListAsync(CancellationToken cancellationToken)
    {
        if (serverListPrepared) return;
        try
        {
            var records = await SteamDirectory.LoadAsync(configuration, cancellationToken).ConfigureAwait(false);
            if (records.Count == 0) return;

            var ordered = records
                .OrderBy(static record => record.GetPort() == 443 ? 0 : 1)
                .ToArray();

            configuration.ServerList.ReplaceList(ordered);
            serverListPrepared = true;
            var httpsCount = ordered.Count(static record => record.GetPort() == 443);
            Console.Error.WriteLine(
                $"[SteamService] CM 候选已重排：{httpsCount}/{ordered.Length} 个 443 端点优先，" +
                $"首个候选 {ordered[0].GetHost()}:{ordered[0].GetPort()}");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error)
        {
            // 目录拉取失败不致命：退回 SteamKit2 内置解析（它自己会再试一次目录，
            // 再退到 DefaultServerWebsocket/DefaultServerNetfilter）。
            Console.Error.WriteLine($"[SteamService] CM 候选重排失败，回退内置逻辑：{error.Message}");
        }
    }

    private async Task EnsureConnectedAsync(CancellationToken cancellationToken)
    {
        if (client.IsConnected) return;
        await PrepareServerListAsync(cancellationToken).ConfigureAwait(false);
        Exception? lastError = null;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            connectedSource = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var started = DateTime.UtcNow;
            try
            {
                client.Connect();
                await connectedSource.Task.WaitAsync(TimeSpan.FromSeconds(12), cancellationToken).ConfigureAwait(false);
                return;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error)
            {
                lastError = error;
                var elapsed = (DateTime.UtcNow - started).TotalMilliseconds;
                Console.Error.WriteLine(
                    $"[SteamService] CM 连接失败 attempt={attempt + 1} elapsed={elapsed:F0}ms " +
                    $"endpoint={client.Configuration.ServerList.GetAllEndPoints().FirstOrDefault()?.GetHost() ?? "-"} " +
                    $"reason={error.Message}");
                connectedSource = null;
                try { client.Disconnect(); } catch { }
                if (attempt < 3)
                {
                    await Task.Delay(TimeSpan.FromMilliseconds(500 * (attempt + 1)), cancellationToken).ConfigureAwait(false);
                }
            }
        }
        throw lastError ?? new ServiceException("CONNECTION_LOST", "Steam connection closed.");
    }

    private async Task LogOnAsync(string username, string refreshToken, uint loginId, CancellationToken cancellationToken)
    {
        loggedOnSource = new TaskCompletionSource<SteamUser.LoggedOnCallback>(TaskCreationOptions.RunContinuationsAsynchronously);
        user.LogOn(new SteamUser.LogOnDetails
        {
            Username = username,
            AccessToken = refreshToken,
            ShouldRememberPassword = true,
            LoginID = loginId
        });
        var result = await loggedOnSource.Task.WaitAsync(TimeSpan.FromSeconds(30), cancellationToken).ConfigureAwait(false);
        if (result.Result != EResult.OK) throw new ServiceException("AUTH_FAILED", result.Result.ToString());
        SteamId = result.ClientSteamID?.ConvertToUInt64().ToString() ?? "";
        IsLoggedIn = true;
    }

    private static void EnsureSuccess(EResult result, string code)
    {
        if (result != EResult.OK)
        {
            throw new ServiceException(code, result.ToString());
        }
    }

    private async Task RunCallbacksAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                await callbacks.RunWaitCallbackAsync(lifetime.Token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
        }
    }

    private void OnConnected(SteamClient.ConnectedCallback callback)
    {
        connectedSource?.TrySetResult(true);
    }

    private void OnDisconnected(SteamClient.DisconnectedCallback callback)
    {
        if (callback.UserInitiated)
        {
            resetConnectionSource?.TrySetResult(true);
            return;
        }
        connectedSource?.TrySetException(new ServiceException("CONNECTION_LOST", "Steam connection closed."));
        loggedOnSource?.TrySetException(new ServiceException("CONNECTION_LOST", "Steam connection closed."));
        if (IsLoggedIn && !shuttingDown)
        {
            IsLoggedIn = false;
            SteamId = "";
            accessToken = "";
            MarkOffline();
            StartRecovery("Steam connection closed.");
        }
    }

    private void OnLoggedOn(SteamUser.LoggedOnCallback callback)
    {
        loggedOnSource?.TrySetResult(callback);
    }

    private void OnLoggedOff(SteamUser.LoggedOffCallback callback)
    {
        if (shuttingDown || !IsLoggedIn) return;
        IsLoggedIn = false;
        SteamId = "";
        accessToken = "";
        MarkOffline();
        StartRecovery(callback.Result.ToString());
    }

    public async ValueTask DisposeAsync()
    {
        shuttingDown = true;
        CancelAuthentication();
        CancelRecovery();
        if (client.IsConnected)
        {
            if (IsLoggedIn) user.LogOff();
            client.Disconnect();
        }
        lifetime.Cancel();
        try { await callbackLoop.ConfigureAwait(false); } catch { }
        lifetime.Dispose();
        authGate.Dispose();
        appInfoGate.Dispose();
        favoriteGate.Dispose();
        contentServerGate.Dispose();
    }
}

internal sealed record SubscriptionPage(
    int TotalResults,
    int StartIndex,
    IReadOnlyList<SubscribedFile> Files);

internal sealed record FavoritePage(
    int TotalResults,
    int StartIndex,
    int NextStartIndex,
    IReadOnlyList<ulong> PublishedFileIds);

internal sealed record SubscribedFile(
    ulong PublishedFileId,
    uint SubscribedAt,
    uint UpdatedAt,
    ulong ContentHash,
    ulong FileSize,
    uint AppId);

internal sealed record SteamComment(
    ulong CommentId,
    ulong AuthorSteamId,
    uint Timestamp,
    string Text,
    int Upvotes,
    bool Hidden);

internal sealed record CommentPage(
    int TotalCount,
    bool CanPost,
    int NextStartIndex,
    IReadOnlyList<SteamComment> Comments);
