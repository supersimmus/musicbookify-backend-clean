..get('/me', (Request req) async {
  final spotifyId = req.url.queryParameters['spotify_id'];
  if (spotifyId == null) {
    return Response(400, body: 'Missing "spotify_id"');
  }

  var tokens = await db.getTokens(spotifyId);
  if (tokens == null) {
    return Response(404, body: 'User not found');
  }

  final expiresAt = tokens['expires_at'] as DateTime;
  if (DateTime.now().toUtc().isAfter(expiresAt)) {
    print('🔁 Token expired – refreshing...');
    final refreshToken = tokens['refresh_token'] as String;

    final tokenRes = await http.post(
      Uri.parse('https://accounts.spotify.com/api/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type':    'refresh_token',
        'refresh_token': refreshToken,
        'client_id':     clientId,
        'client_secret': clientSecret,
      },
    );

    if (tokenRes.statusCode != 200) {
      return Response(tokenRes.statusCode,
          body: 'Token refresh failed: ${tokenRes.body}');
    }

    final tokenJson   = jsonDecode(tokenRes.body) as Map<String, dynamic>;
    final accessToken = tokenJson['access_token'] as String;
    final expiresIn   = tokenJson['expires_in'] as int;
    final newRefresh  = tokenJson['refresh_token'] ?? refreshToken;
    final newExpires  = DateTime.now().toUtc().add(Duration(seconds: expiresIn));

    await db.saveTokens(
      spotifyId:    spotifyId,
      accessToken:  accessToken,
      refreshToken: newRefresh,
      expiresAt:    newExpires,
    );

    tokens = {
      'access_token':  accessToken,
      'refresh_token': newRefresh,
      'expires_at':    newExpires,
    };
    print('✅ Token refreshed for $spotifyId');
  }

  final profileRes = await http.get(
    Uri.parse('https://api.spotify.com/v1/me'),
    headers: {'Authorization': 'Bearer ${tokens['access_token']}'},
  );
  if (profileRes.statusCode != 200) {
    return Response(profileRes.statusCode,
        body: 'Failed to fetch profile: ${profileRes.body}');
  }

  return Response.ok(
    profileRes.body,
    headers: {'Content-Type': 'application/json'},
  );
})
