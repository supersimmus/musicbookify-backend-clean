import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MobileAds.instance.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Bookify',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Colors.amber,
          secondary: Colors.teal,
        ),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _bookController = TextEditingController(text: 'The Hobbit');
  bool _loading = false;
  String _spotifyUrl = '';
  List<String> _youtubeUrls = [];

  final InAppPurchase _iap = InAppPurchase.instance;
  static const String _removeAdsId = 'remove_ads';
  static const String _donateId = 'donate_me';
  bool _iapAvailable = false;
  bool isPremium = false;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSub;

  BannerAd? _bannerAd;
  bool _isBannerReady = false;

  @override
  void initState() {
    super.initState();
    _initMonetization();
  }

  Future<void> _initMonetization() async {
    await _loadPremiumStatus();
    _initBannerIfNeeded();
    await _initIap();
    await _restorePurchases();
  }

  Future<void> _loadPremiumStatus() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isPremium = prefs.getBool('isPremium') ?? false;
    });
  }

  void _initBannerIfNeeded() {
    if (isPremium) return;
    _bannerAd = BannerAd(
      adUnitId: 'ca-app-pub-7113473511307893/4535166756', // PROD
      // adUnitId: 'ca-app-pub-3940256099942544/6300978111', // TEST
      request: const AdRequest(),
      size: AdSize.banner,
      listener: BannerAdListener(
        onAdLoaded: (_) => setState(() => _isBannerReady = true),
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          setState(() => _isBannerReady = false);
        },
      ),
    )..load();
  }

  Future<void> _initIap() async {
    _iapAvailable = await _iap.isAvailable();
    if (!_iapAvailable) return;

    _purchaseSub = _iap.purchaseStream.listen(
      (purchases) => _onPurchaseUpdate(purchases),
      onError: (e) => _showSnack('Chyba nákupu: $e'),
    );
  }

  Future<void> _restorePurchases() async {
    if (!_iapAvailable) return;
    await _iap.restorePurchases();
  }

  Future<void> _onPurchaseUpdate(List<PurchaseDetails> purchases) async {
    final prefs = await SharedPreferences.getInstance();

    for (final p in purchases) {
      if (p.status == PurchaseStatus.purchased ||
          p.status == PurchaseStatus.restored) {
        if (p.productID == _removeAdsId) {
          await prefs.setBool('isPremium', true);
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
          if (mounted) {
            setState(() {
              isPremium = true;
              _isBannerReady = false;
            });
          }
          _bannerAd?.dispose();
          _showSnack('Děkujeme za podporu. Reklamy byly odstraněny.');
        }

        if (p.productID == _donateId) {
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
          _showSnack('Děkujeme za dar! ❤️');
        }
      } else if (p.status == PurchaseStatus.error) {
        _showSnack('Nákup selhal: ${p.error}');
      }
    }
  }

  @override
  void dispose() {
    _bookController.dispose();
    _bannerAd?.dispose();
    _purchaseSub?.cancel();
    super.dispose();
  }

  Future<void> _buyRemoveAds() async {
    if (!_iapAvailable) {
      _showSnack('Nákupy nejsou dostupné. Zkuste později.');
      return;
    }
    final resp = await _iap.queryProductDetails({_removeAdsId});
    if (resp.productDetails.isEmpty) {
      _showSnack('Produkt „Remove Ads” není publikován.');
      return;
    }
    final param = PurchaseParam(productDetails: resp.productDetails.first);
    await _iap.buyNonConsumable(purchaseParam: param);
  }

  Future<void> _donate() async {
    if (!_iapAvailable) {
      _showSnack('Nákupy nejsou dostupné. Zkuste později.');
      return;
    }
    final resp = await _iap.queryProductDetails({_donateId});
    if (resp.productDetails.isEmpty) {
      _showSnack('Produkt „Donate me” není publikován.');
      return;
    }
    final param = PurchaseParam(productDetails: resp.productDetails.first);
    await _iap.buyConsumable(purchaseParam: param);
  }

  void _showSnack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _showSnack('Nelze otevřít odkaz');
    }
  }

  Future<void> _onSpotifyPressed() async {
    final book = _bookController.text.trim();
    if (book.isEmpty) return _showSnack('Zadej název knihy');

    setState(() {
      _loading = true;
      _spotifyUrl = '';
      _youtubeUrls = [];
    });

    try {
      final resp = await http.post(
        Uri.parse('https://musicbookify-backend-production.up.railway.app/create-playlist'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'bookTitle': book}),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        setState(() => _spotifyUrl = data['url']);
      } else {
        _showSnack('Chyba při vytváření playlistu');
      }
    } catch (e) {
      _showSnack('Spotify chyba: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _onYoutubePressed() async {
    final book = _bookController.text.trim();
    if (book.isEmpty) return _showSnack('Zadej název knihy');

    setState(() {
      _loading = true;
      _spotifyUrl = '';
      _youtubeUrls = [];
    });

    const apiKey = 'AIzaSyB_y3-CMiLISyfGlscubqBcXobhMaQf27Y';
    final query = Uri.encodeComponent(book);

    try {
      final resp = await http.get(Uri.parse(
        'https://www.googleapis.com/youtube/v3/search'
        '?part=snippet&type=video&maxResults=5&q=$query&key=$apiKey',
      ));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final urls = (data['items'] as List)
            .map((item) => 'https://www.youtube.com/watch?v=${item['id']['videoId']}')
            .toList();
        setState(() => _youtubeUrls = urls);
      } else {
        _showSnack('Chyba při načítání videí z YouTube: ${resp.statusCode}');
      }
    } catch (e) {
      _showSnack('YouTube chyba: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const SizedBox(height: 8),
                const Icon(Icons.menu_book, color: Colors.amber, size: 48),
                const SizedBox(height: 8),
                const Text(
                  'Zadej název knihy',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bookController,
                  decoration: const InputDecoration(
                    hintText: 'The Hobbit',
                    filled: true,
                    fillColor: Color(0xFF111111),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.music_note),
                        label: const Text('Spotify playlist'),
                        onPressed: _loading ? null : _onSpotifyPressed,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.video_library),
                        label: const Text('YouTube videa'),
                        onPressed: _loading ? null : _onYoutubePressed,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_loading) const LinearProgressIndicator(),
                if (_spotifyUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ListTile(
                    leading: const Icon(Icons.open_in_new),
                    title: const Text('Otevřít v Spotify'),
                    subtitle: Text(_spotifyUrl),
                    onTap: () => _openUrl(_spotifyUrl),
                  ),
                ],
                if (_youtubeUrls.isNotEmpty) ...[
                  const Divider(height: 24),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'YouTube videa',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _youtubeUrls.length,
                      itemBuilder: (_, i) => ListTile(
                        leading: const Icon(Icons.play_circle),
                        title: Text('Video #${i + 1}'),
                        subtitle: Text(_youtubeUrls[i]),
                        onTap: () => _openUrl(_youtubeUrls[i]),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Banner pouze pro ne-premium
        if (!isPremium && _isBannerReady)
          SizedBox(
            height: _bannerAd!.size.height.toDouble(),
            width: _bannerAd!.size.width.toDouble(),
            child: AdWidget(ad: _bannerAd!),
          ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Music Bookify'),
        actions: [
          if (!isPremium)
            TextButton.icon(
              onPressed: _buyRemoveAds,
              icon: const Icon(Icons.block, color: Colors.amber),
              label: const Text(
                'Odstranit reklamy',
                style: TextStyle(color: Colors.white),
              ),
            ),
          TextButton.icon(
            onPressed: _donate,
            icon: const Icon(Icons.volunteer_activism, color: Colors.amber),
            label: const Text(
              'Donate me',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: body,
    );
  }
}
