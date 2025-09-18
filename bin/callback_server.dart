// callback_server.dart

import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

Future<void> handle(HttpRequest request) async {
  // Získání autorizačního kódu z query parametru
  final code = request.uri.queryParameters['code'];
  if (code == null) {
    request.response
      ..statusCode = 400
      ..write('❌ Chybí parametr code')
      ..close();
    return;
  }

  // Načtení tajných proměnných z prostředí
  final clientId = Platform.environment['SPOTIFY_CLIENT_ID']!;
  final clientSecret = Platform.environment['SPOTIFY_CLIENT_SECRET']!;
  final redirectUri = Platform.environment['SPOTIFY_REDIRECT_URI']!;

  // Připravíme Basic auth header
  final authHeader = base64Encode(utf8.encode('$clientId:$clientSecret'));

  // Požadavek na výměnu kódu za tokeny
  final resp = await http.post(
    Uri.parse('https://accounts.spotify.com/api/token'),
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': 'Basic $authHeader',
    },
    body: {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': redirectUri,
    },
  );

  // Zpracování chyby
  if (resp.statusCode != 200) {
    request.response
      ..statusCode = resp.statusCode
      ..write('❌ Chyba při získávání tokenu: ${resp.body}')
      ..close();
    return;
  }

  // Parsování odpovědi
  final data = jsonDecode(resp.body);
  final accessToken = data['access_token'];
  final refreshToken = data['refresh_token'];

  // Odpověď v HTML s odkazy pro další volání
  request.response
    ..statusCode = 200
    ..headers.contentType = ContentType.html
    ..write('''
      <h1>✅ Přihlášení úspěšné</h1>
      <p>Access Token: <code>$accessToken</code></p>
      <p>Refresh Token: <code>$refreshToken</code></p>
      <p>
        <a href="/me?access_token=$accessToken">
          Klikni sem pro zobrazení profilu &rarr; /me
        </a>
      </p>
    ''')
    ..close();
}
