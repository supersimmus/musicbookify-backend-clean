// lib/services/spotify_auth_service.dart

import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_web_auth/flutter_web_auth.dart';
import 'package:http/http.dart' as http;

class SpotifyAuthService {
  final _clientId     = dotenv.env['SPOTIFY_CLIENT_ID']!;
  final _clientSecret = dotenv.env['SPOTIFY_CLIENT_SECRET']!;
  final _redirectUri  = dotenv.env['SPOTIFY_REDIRECT_URI']!; // např. "bookify://callback"
  final _scopes       = 'playlist-modify-private playlist-modify-public';

  Future<String> authenticate() async {
    // 1) Otevři Spotify OAuth stránku
    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id'     : _clientId,
      'response_type' : 'code',
      'redirect_uri'  : _redirectUri,
      'scope'         : _scopes,
      'show_dialog'   : 'true',
    }).toString();

    // 2) Čekej na redirect (musíš mít intent-filter v AndroidManifest.xml / URL scheme v Info.plist)
    final result = await FlutterWebAuth.authenticate(
      url: authUrl,
      callbackUrlScheme: Uri.parse(_redirectUri).scheme,
    );

    // 3) Extrahuj code a vyměň za token
    final code = Uri.parse(result).queryParameters['code']!;
    final tokenRes = await http.post(
      Uri.parse('https://accounts.spotify.com/api/token'),
      headers: {
        'Authorization': 'Basic ' +
            base64Encode(utf8.encode('$_clientId:$_clientSecret')),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'grant_type'   : 'authorization_code',
        'code'         : code,
        'redirect_uri' : _redirectUri,
      },
    );
    if (tokenRes.statusCode != 200) {
      throw Exception('Spotify auth failed: ${tokenRes.body}');
    }
    return jsonDecode(tokenRes.body)['access_token'] as String;
  }
}
