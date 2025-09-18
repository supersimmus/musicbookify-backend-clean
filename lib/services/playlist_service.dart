// lib/services/playlist_service.dart

import 'package:book_music_app/services/openai_service.dart';
import 'package:book_music_app/services/spotify_auth_service.dart';
import 'package:book_music_app/services/spotify_playlist_service.dart';
import 'package:book_music_app/services/youtube_service.dart';

class PlaylistService {
  final _openAI = OpenAIService();
  final _auth = SpotifyAuthService();
  final _spotify = SpotifyPlaylistService();
  final _yt = YouTubeService();

  /// Vygeneruje Spotify playlist pro danou knihu, vrátí URL playlistu.
  Future<String> createSpotifyPlaylist(String book) async {
    final tracks = await _openAI.generateTrackList(book);
    final token = await _auth.authenticate();
    final uris = await _spotify.searchTrackUris(token, tracks);
    return await _spotify.createAndPopulatePlaylist(token, uris);
  }

  /// Vygeneruje YouTube preview videa podle knihy.
  Future<List<String>> createYoutubePreview(String book) async {
    final tracks = await _openAI.generateTrackList(book);
    return await _yt.getVideoUrls(tracks);
  }
}
