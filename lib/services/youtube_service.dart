// lib/services/youtube_service.dart

import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class YouTubeService {
  final _apiKey = dotenv.env['YOUTUBE_API_KEY']!;

  Future<List<String>> getVideoUrls(List<String> queries) async {
    final urls = <String>[];
    for (final query in queries) {
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/search', {
        'part': 'snippet',
        'maxResults': '1',
        'q': query,
        'type': 'video',
        'key': _apiKey,
      });
      final res = await http.get(uri);
      if (res.statusCode != 200) continue;
      final items = jsonDecode(res.body)['items'] as List;
      if (items.isEmpty) continue;
      final videoId = items.first['id']['videoId'] as String;
      urls.add('https://www.youtube.com/watch?v=$videoId');
    }
    return urls;
  }
}
