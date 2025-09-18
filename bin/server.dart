// bin/server.dart

import 'dart:io';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';

/// CORS hlavičky pro všechny odpovědi
const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

/// Middleware, který obslouží OPTIONS a přidá CORS hlavičky
Middleware corsMiddleware = (Handler inner) {
  return (Request req) async {
    if (req.method == 'OPTIONS') {
      return Response.ok('', headers: _corsHeaders);
    }
    final res = await inner(req);
    return res.change(headers: _corsHeaders);
  };
};

/// PostgreSQL helper
class Db {
  late final PostgreSQLConnection _conn;

  Db() {
    final dbUrl = Platform.environment['DATABASE_URL'];
    if (dbUrl == null) {
      stderr.writeln('❌ Missing DATABASE_URL');
      exit(1);
    }
    final uri = Uri.parse(dbUrl);
    _conn = PostgreSQLConnection(
      uri.host,
      uri.port,
      uri.path.substring(1),
      username: uri.userInfo.split(':')[0],
      password: uri.userInfo.split(':')[1],
      useSSL: true,
    );
  }

  Future<void> connect() async {
    await _conn.open();
  }

  Future<void> migrate() async {
    await _conn.query('''
      CREATE TABLE IF NOT EXISTS users (
        id             SERIAL PRIMARY KEY,
        spotify_id     TEXT    UNIQUE NOT NULL,
        access_token   TEXT    NOT NULL,
        refresh_token  TEXT    NOT NULL,
        expires_at     TIMESTAMPTZ NOT NULL,
        updated_at     TIMESTAMPTZ DEFAULT NOW()
      );
    ''');
    print('🧱 Migration applied: users table ready');
  }

  Future<void> saveTokens({
    required String spotifyId,
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) {
    return _conn.query(r'''
      INSERT INTO users (spotify_id, access_token, refresh_token, expires_at)
      VALUES (@sid, @at, @rt, @exp)
      ON CONFLICT (spotify_id) DO UPDATE
        SET access_token  = EXCLUDED.access_token,
            refresh_token = EXCLUDED.refresh_token,
            expires_at    = EXCLUDED.expires_at,
            updated_at    = NOW();
    ''', substitutionValues: {
      'sid': spotifyId,
      'at':  accessToken,
      'rt':  refreshToken,
      'exp': expiresAt.toUtc(),
    });
  }

  Future<Map<String, dynamic>?> getTokens(String spotifyId) async {
    final rows = await _conn.query(r'''
      SELECT access_token, refresh_token, expires_at
      FROM users
      WHERE spotify_id = @sid
      LIMIT 1;
    ''', substitutionValues: {
      'sid': spotifyId,
    });

    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'access_token':  r[0] as String,
      'refresh_token': r[1] as String,
      'expires_at':    (r[2] as DateTime).toUtc(),
    };
  }
}

/// Vytvoří krátkou frázi pro vyhledávání playlistů pomocí OpenAI
Future<String> buildSearchQuery(String bookTitle) async {
  final apiKey = Platform.environment['OPENAI_API_KEY'];
  if (apiKey == null) {
    throw Exception('Missing OPENAI_API_KEY');
  }

  final resp = await http.post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: jsonEncode({
      'model': 'gpt-3.5-turbo',
      'messages': [
        {
          'role': 'system',
          'content':
              'You are an assistant that generates concise search phrases '
              'for playlists to listen to while reading a given book.'
        },
        {
          'role': 'user',
          'content':
              'Generate a short Spotify/YouTube playlist search phrase '
              'for reading the book titled "$bookTitle".'
        },
      ],
      'temperature': 0.7,
    }),
  );

  if (resp.statusCode != 200) {
    throw Exception('OpenAI error: ${resp.body}');
  }

  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final choices = data['choices'] as List<dynamic>?;
  if (choices == null || choices.isEmpty) {
    throw Exception('OpenAI returned no choices: ${resp.body}');
  }
  final message = (choices[0] as Map<String, dynamic>)['message'] as Map?;
  final content = message?['content'] as String?;
  if (content == null) {
    throw Exception('OpenAI response missing content: ${resp.body}');
  }

  return content.trim();
}

/// Vyhledá Spotify playlisty a ošetří možná null
Future<List<Map<String, dynamic>>> searchSpotifyPlaylists(
    String accessToken,
    String query, {
    int limit = 5,
  }) async {
  final uri = Uri.https('api.spotify.com', '/v1/search', {
    'q': query,
    'type': 'playlist',
    'limit': '$limit',
  });

  final resp = await http.get(
    uri,
    headers: {'Authorization': 'Bearer $accessToken'},
  );
  if (resp.statusCode != 200) {
    throw Exception('Spotify search failed: ${resp.body}');
  }

  final jsonBody = jsonDecode(resp.body) as Map<String, dynamic>;
  final playlists = jsonBody['playlists'];
  if (playlists is! Map<String, dynamic>) {
    throw Exception('Invalid Spotify "playlists" object');
  }
  final items = playlists['items'];
  if (items is! List<dynamic>) {
    throw Exception('Spotify "items" is not a list');
  }

  return items.cast<Map<String, dynamic>>().map((p) {
    final ext = p['external_urls'] as Map<String, dynamic>?;
    final url = ext != null && ext['spotify'] is String
        ? ext['spotify'] as String
        : '';
    final imgs = p['images'] as List<dynamic>?;
    final imgUrl = (imgs != null && imgs.isNotEmpty && imgs[0]['url'] is String)
        ? imgs[0]['url'] as String
        : null;

    return {
      'name':        p['name'] as String? ?? '',
      'description': p['description'] as String? ?? '',
      'url':         url,
      'image':       imgUrl,
    };
  }).toList();
}

/// Vyhledá YouTube playlisty přes Data API
Future<List<Map<String, dynamic>>> searchYouTubePlaylists(
    String apiKey,
    String query, {
    int limit = 5,
  }) async {
  final uri = Uri.https('www.googleapis.com', '/youtube/v3/search', {
    'part':       'snippet',
    'type':       'playlist',
    'maxResults': '$limit',
    'q':          query,
    'key':        apiKey,
  });

  final resp = await http.get(uri);
  if (resp.statusCode != 200) {
    throw Exception('YouTube search failed: ${resp.body}');
  }

  final jsonBody = jsonDecode(resp.body) as Map<String, dynamic>;
  final items = jsonBody['items'];
  if (items is! List<dynamic>) {
    throw Exception('Invalid YouTube "items"');
  }

  return items.cast<Map<String, dynamic>>().map((item) {
    final sn = item['snippet'] as Map<String, dynamic>? ?? {};
    final idObj = item['id'] as Map<String, dynamic>? ?? {};
    final playlistId = idObj['playlistId'] as String? ?? '';
    final thumbs = sn['thumbnails'] as Map<String, dynamic>? ?? {};
    final medium = thumbs['medium'] as Map<String, dynamic>? ?? {};
    final thumbUrl = medium['url'] as String? ?? '';

    return {
      'name':        sn['title'] as String? ?? '',
      'description': sn['description'] as String? ?? '',
      'url':         'https://www.youtube.com/playlist?list=$playlistId',
      'image':       thumbUrl,
    };
  }).toList();
}

Future<void> main() async {
  // Nastavení serveru
  final ip   = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');

  // Env-vars pro Spotify
  final clientId     = Platform.environment['SPOTIFY_CLIENT_ID']     ?? '';
  final clientSecret = Platform.environment['SPOTIFY_CLIENT_SECRET'] ?? '';
  final redirectUri  = Platform.environment['REDIRECT_URI']          ?? '';
  if (clientId.isEmpty || clientSecret.isEmpty || redirectUri.isEmpty) {
    stderr.writeln('❌ Missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET / REDIRECT_URI');
    exit(1);
  }

  // Připojení k DB
  final db = Db();
  await db.connect();
  await db.migrate();
  print('✅ Connected to Postgres');

  // Router
  final router = Router()

    // Health-check
    ..get('/', (_) => Response.ok('🎵 MusicBookify Backend OK'))

    // Spotify OAuth callback
    ..get('/callback', (Request req) async {
      final code = req.url.queryParameters['code'];
      if (code == null) {
        return Response(400, body: 'Missing "code"');
      }

      // Výměna kódu za tokeny
      final tokenRes = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type':    'authorization_code',
          'code':          code,
          'redirect_uri':  redirectUri,
          'client_id':     clientId,
          'client_secret': clientSecret,
        },
      );
      if (tokenRes.statusCode != 200) {
        return Response(tokenRes.statusCode,
            body: 'Token exchange failed: ${tokenRes.body}');
      }

      final tj  = jsonDecode(tokenRes.body) as Map<String, dynamic>;
      final at  = tj['access_token']  as String;
      final rt  = tj['refresh_token'] as String;
      final exp = (tj['expires_in'] as int);
      final expAt = DateTime.now().toUtc().add(Duration(seconds: exp));

      // Získání Spotify ID uživatele
      final profRes = await http.get(
        Uri.parse('https://api.spotify.com/v1/me'),
        headers: {'Authorization': 'Bearer $at'},
      );
      if (profRes.statusCode != 200) {
        return Response(profRes.statusCode,
            body: 'Failed to fetch profile: ${profRes.body}');
      }
      final profJson = jsonDecode(profRes.body) as Map<String, dynamic>;
      final sid = profJson['id'] as String;

      // Uložení tokenů do DB
      await db.saveTokens(
        spotifyId:    sid,
        accessToken:  at,
        refreshToken: rt,
        expiresAt:    expAt,
      );

      return Response.ok(jsonEncode({
        'spotify_id':   sid,
        'access_token': at,
        'refresh_token': rt,
        'expires_in':    exp,
      }), headers: {'Content-Type': 'application/json'});
    })

    // Získat info o uživateli, automatický refresh
    ..get('/me', (Request req) async {
      final sid = req.url.queryParameters['spotify_id'];
      if (sid == null) return Response(400, body: 'Missing "spotify_id"');

      var tokens = await db.getTokens(sid);
      if (tokens == null) return Response(404, body: 'User not found');

      // Pokud expirováno, refresh
      final expAt = tokens['expires_at'] as DateTime;
      if (DateTime.now().toUtc().isAfter(expAt)) {
        final oldRt = tokens['refresh_token'] as String;
        final refRes = await http.post(
          Uri.parse('https://accounts.spotify.com/api/token'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type':    'refresh_token',
            'refresh_token': oldRt,
            'client_id':     clientId,
            'client_secret': clientSecret,
          },
        );
        if (refRes.statusCode != 200) {
          return Response(refRes.statusCode,
              body: 'Token refresh failed: ${refRes.body}');
        }
        final tj2  = jsonDecode(refRes.body) as Map<String, dynamic>;
        final newAt  = tj2['access_token'] as String;
        final newRt  = (tj2['refresh_token'] as String?) ?? oldRt;
        final newExp = (tj2['expires_in'] as int);
        final newExpAt = DateTime.now().toUtc().add(Duration(seconds: newExp));

        await db.saveTokens(
          spotifyId:    sid,
          accessToken:  newAt,
          refreshToken: newRt,
          expiresAt:    newExpAt,
        );
        tokens = {
          'access_token':  newAt,
          'refresh_token': newRt,
          'expires_at':    newExpAt,
        };
      }

      final profileRes = await http.get(
        Uri.parse('https://api.spotify.com/v1/me'),
        headers: {'Authorization': 'Bearer ${tokens['access_token']}'},
      );
      return Response.ok(profileRes.body,
          headers: {'Content-Type': 'application/json'});
    })

    // Explicitní endpoint pro refresh tokenů
    ..get('/refresh', (Request req) async {
      final sid = req.url.queryParameters['spotify_id'];
      if (sid == null) return Response(400, body: 'Missing "spotify_id"');

      final tokens = await db.getTokens(sid);
      if (tokens == null) return Response(404, body: 'User not found');

      final oldRt = tokens['refresh_token'] as String;
      final refRes = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type':    'refresh_token',
          'refresh_token': oldRt,
          'client_id':     clientId,
          'client_secret': clientSecret,
        },
      );
      if (refRes.statusCode != 200) {
        return Response(refRes.statusCode,
            body: 'Token refresh failed: ${refRes.body}');
      }
      final tj2  = jsonDecode(refRes.body) as Map<String, dynamic>;
      final newAt   = tj2['access_token'] as String;
      final newRt   = (tj2['refresh_token'] as String?) ?? oldRt;
      final newExp  = (tj2['expires_in'] as int);
      final newExpAt = DateTime.now().toUtc().add(Duration(seconds: newExp));

      await db.saveTokens(
        spotifyId:    sid,
        accessToken:  newAt,
        refreshToken: newRt,
        expiresAt:    newExpAt,
      );

      return Response.ok(jsonEncode({
        'spotify_id':    sid,
        'access_token':  newAt,
        'refresh_token': newRt,
        'expires_in':    newExp,
      }), headers: {'Content-Type': 'application/json'});
    })

    // Hlavní endpoint – generate + search
    ..get('/recommend', (Request req) async {
      try {
        final sid       = req.url.queryParameters['spotify_id'];
        final bookTitle = req.url.queryParameters['book_title'];
        final provider  = req.url.queryParameters['provider'] ?? 'spotify';

        if (sid == null || bookTitle == null) {
          return Response(400,
              body: 'Missing "spotify_id" or "book_title"');
        }

        // Zajistit platné tokeny
        var tokens = await db.getTokens(sid);
        if (tokens == null) return Response(404, body: 'User not found');

        // Pokud expirováno, refresh (můžeme DRY ten kód)
        final expAt = tokens['expires_at'] as DateTime;
        if (DateTime.now().toUtc().isAfter(expAt)) {
          final oldRt = tokens['refresh_token'] as String;
          final refRes = await http.post(
            Uri.parse('https://accounts.spotify.com/api/token'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {
              'grant_type':    'refresh_token',
              'refresh_token': oldRt,
              'client_id':     clientId,
              'client_secret': clientSecret,
            },
          );
          if (refRes.statusCode != 200) {
            return Response(refRes.statusCode,
                body: 'Token refresh failed: ${refRes.body}');
          }
          final tj2 = jsonDecode(refRes.body) as Map<String, dynamic>;
          final newAt   = tj2['access_token'] as String;
          final newRt   = (tj2['refresh_token'] as String?) ?? oldRt;
          final newExp  = (tj2['expires_in'] as int);
          final newExpAt = DateTime.now().toUtc()
              .add(Duration(seconds: newExp));

          await db.saveTokens(
            spotifyId:    sid,
            accessToken:  newAt,
            refreshToken: newRt,
            expiresAt:    newExpAt,
          );
          tokens = {
            'access_token':  newAt,
            'refresh_token': newRt,
            'expires_at':    newExpAt,
          };
        }

        // vygenerovat frázi
        final searchQuery = await buildSearchQuery(bookTitle);

        // zavolat Spotify nebo YouTube
        List<Map<String, dynamic>> playlists;
        if (provider == 'youtube') {
          final ytKey = Platform.environment['YOUTUBE_API_KEY'];
          if (ytKey == null) {
            return Response(500, body: 'Missing YOUTUBE_API_KEY');
          }
          playlists = await searchYouTubePlaylists(ytKey, searchQuery);
        } else {
          playlists = await searchSpotifyPlaylists(
            tokens['access_token'] as String,
            searchQuery,
          );
        }

        return Response.ok(jsonEncode({
          'book_title': bookTitle,
          'query':      searchQuery,
          'provider':   provider,
          'playlists':  playlists,
        }), headers: {'Content-Type': 'application/json'});
      } catch (e, st) {
        stderr.writeln('❌ /recommend failed: $e\n$st');
        return Response.internalServerError(
            body: 'InternalServerError: $e');
      }
    });

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(corsMiddleware)
      .addHandler(router);

  final server = await io.serve(handler, ip, port);
  print('🚀 Server running on http://${server.address.host}:${server.port}');
}
