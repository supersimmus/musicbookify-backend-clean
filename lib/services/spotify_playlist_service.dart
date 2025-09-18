// lib/services/spotify_playlist_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;

class SpotifyPlaylistService {
  Future<String> _getUserId(String token) async {
    final res = await http.get(
      Uri.parse('https://api.spotify.com/v1/me'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode != 200) {
      throw Exception('Spotify /me failed: ${res.body}');
    }
    return jsonDecode(res.body)['id'] as String;
  }

  Future<List<String>> searchTrackUris(String token, List<String> tracks) async {
    final uris = <String>[];
    for (var track in tracks) {
      final q = Uri.encodeQueryComponent(track);
      final res = await http.get(
        Uri.parse('https://api.spotify.com/v1/search?q=$q&type=track&limit=1'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 200) {
        final items = jsonDecode(res.body)['tracks']['items'] as List;
        if (items.isNotEmpty) {
          uris.add(items.first['uri'] as String);
        }
      }
    }
    return uris;
  }

  Future<String> createAndPopulatePlaylist(
      String token, List<String> uris) async {
    final userId = await _getUserId(token);
    final createRes = await http.post(
      Uri.parse('https://api.spotify.com/v1/users/$userId/playlists'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'name': 'Bookify Playlist',
        'description': 'Generated with Music Bookify',
        'public': false,
      }),
    );
    if (createRes.statusCode != 201) {
      throw Exception('Create playlist failed: ${createRes.body}');
    }
    final playlistData = jsonDecode(createRes.body);
    final playlistId = playlistData['id'] as String;

    final addRes = await http.post(
      Uri.parse(
          'https://api.spotify.com/v1/playlists/$playlistId/tracks'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'uris': uris}),
    );
    if (addRes.statusCode != 201) {
      throw Exception('Add tracks failed: ${addRes.body}');
    }

    return playlistData['external_urls']['spotify'] as String;
  }
}
