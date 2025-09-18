// lib/services/openai_service.dart

import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

class OpenAIService {
  final _apiKey = dotenv.env['OPENAI_API_KEY']!;
  final _baseUrl = 'https://api.openai.com/v1';

  Future<List<String>> generateTrackList(String book) async {
    final uri = Uri.parse('$_baseUrl/chat/completions');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_apiKey',
      },
      body: jsonEncode({
        'model': 'gpt-3.5-turbo',
        'messages': [
          {
            'role': 'system',
            'content': 'You are a creative playlist curator.'
          },
          {
            'role': 'user',
            'content':
                'Generate a JSON array of 10 songs in the format "Song Title - Artist" that match the mood and themes of the book titled: "$book".'
          }
        ],
        'max_tokens': 200,
        'temperature': 0.7,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('OpenAI error: ${response.statusCode} - ${response.body}');
    }

    final data = jsonDecode(response.body);
    final content = data['choices'][0]['message']['content'] as String;
    final lines = content.split('\n');
    final tracks = <String>[];

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      line = line.replaceFirst(RegExp(r'^\d+\.?\s*'), '');
      tracks.add(line);
    }
    return tracks;
  }
}
