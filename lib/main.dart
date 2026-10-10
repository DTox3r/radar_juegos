import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

const String periodicTaskName = "com.radargamer.checkDealsTask";

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedStr = prefs.getString('followed_games_list');
      if (savedStr == null) return Future.value(true);

      final List followed = jsonDecode(savedStr);
      for (var g in followed) {
        final res = await http.get(Uri.parse('https://www.cheapshark.com/api/1.0/games?id=${g['gameID']}'));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final deals = data['deals'] as List? ?? [];
          if (deals.isNotEmpty) {
            final best = deals.first;
            final prevPrice = double.tryParse(g['salePrice'].toString()) ?? 0.0;
            final currPrice = double.tryParse(best['price'].toString()) ?? 0.0;

            if (currPrice < prevPrice && prevPrice > 0) {
              const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
                'deals_channel',
                'Alertas de Ofertas',
                channelDescription: 'Notificaciones con sonido cuando bajan de precio los juegos seguidos',
                importance: Importance.max,
                priority: Priority.high,
                playSound: true,
                enableVibration: true,
              );
              const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);
              await flutterLocalNotificationsPlugin.show(
                DateTime.now().millisecond,
                '🔥 ¡Oferta en ${data['info']['title']}!',
                'Bajó a \$${currPrice.toStringAsFixed(2)} en tienda oficial',
                platformDetails,
              );
            }
          }
        }
      }
    } catch (_) {}
    return Future.value(true);
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const AndroidInitializationSettings initAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings =
      InitializationSettings(android: initAndroid);
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  Workmanager().registerPeriodicTask(
    "dealCheckTask",
    periodicTaskName,
    frequency: const Duration(hours: 4),
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
  );

  runApp(const RadarGamerApp());
}

class RadarGamerApp extends StatelessWidget {
  const RadarGamerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radar Gamer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F17),
        primaryColor: const Color(0xFF00D2FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D2FF),
          secondary: Color(0xFF00F5A0),
          surface: Color(0xFF141B26),
        ),
        cardTheme: const CardThemeData(
          color: Color(0xFF141B26),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFF1F293D), width: 1),
          ),
        ),
        fontFamily: 'Roboto',
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  double _vesRate = 0.0;
  bool _isLoadingRate = true;
  String _region = 'LATAM';
  Map<String, String> _storesMap = {};

  List<Map<String, dynamic>> _followedGames = [];
  List<Map<String, dynamic>> _deals = [];
  bool _isLoadingDeals = true;

  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'es_VE');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _requestNotificationPermissions();
    _initializeData();
  }

  Future<void> _requestNotificationPermissions() async {
    final androidImpl = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
  }

  Future<void> _initializeData() async {
    await _loadStores();
    await _loadLocalSettings();
    await Future.wait([
      _fetchBinanceRate(),
      _fetchDeals(),
      _refreshFollowed(),
    ]);
  }

  Future<void> _loadStores() async {
    try {
      final res = await http.get(Uri.parse('https://www.cheapshark.com/api/1.0/stores'));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        final Map<String, String> map = {};
        for (var s in list) {
          map[s['storeID'].toString()] = s['storeName'].toString();
        }
        setState(() => _storesMap = map);
      }
    } catch (_) {}
  }

  Future<void> _loadLocalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _region = prefs.getString('saved_region') ?? 'LATAM';
      final savedFollowed = prefs.getString('followed_games_list');
      if (savedFollowed != null) {
        _followedGames = List<Map<String, dynamic>>.from(jsonDecode(savedFollowed));
      }
    });
  }

  Future<void> _saveFollowed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('followed_games_list', jsonEncode(_followedGames));
  }

  Future<void> _saveRegion(String region) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_region', region);
    setState(() => _region = region);
  }

  Future<void> _fetchBinanceRate() async {
    setState(() => _isLoadingRate = true);
    try {
      final url = Uri.parse('https://p2p.binance.com/bapi/c2c/v2/friendly/c2c/adv/search');
      final payload = {
        "fiat": "VES",
        "page": 1,
        "rows": 10,
        "tradeType": "BUY",
        "asset": "USDT",
        "countries": [],
        "proMerchantAds": false,
        "shieldMerchantAds": false,
        "filterType": "all",
        "periods": [],
        "additionalKycVerifyFilter": 0,
        "publisherType": null,
        "payTypes": []
      };

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List ads = data['data'] ?? [];
        if (ads.isNotEmpty) {
          double total = 0.0;
          int count = 0;
          for (var item in ads) {
            final p = double.tryParse(item['adv']['price'].toString());
            if (p != null) {
              total += p;
              count++;
            }
          }
          if (count > 0) {
            setState(() {
              _vesRate = total / count;
              _isLoadingRate = false;
            });
            return;
          }
        }
      }
    } catch (_) {}

    setState(() {
      if (_vesRate == 0.0) _vesRate = 1015.00;
      _isLoadingRate = false;
    });
  }

  Future<void> _fetchDeals() async {
    setState(() => _isLoadingDeals = true);
    try {
      final res = await http.get(Uri.parse(
          'https://www.cheapshark.com/api/1.0/deals?storeID=1,2,3,7,11,25,31&pageSize=30&sortBy=Deal%20Rating'));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        setState(() {
          _deals = list.cast<Map<String, dynamic>>();
          _isLoadingDeals = false;
        });
        return;
      }
    } catch (_) {}
    setState(() => _isLoadingDeals = false);
  }

  void _triggerNotificationWithSound(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'deals_channel',
      'Alertas de Ofertas',
      channelDescription: 'Canal principal para notificaciones de rebajas',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(0, title, body, platformDetails);
  }

  Future<void> _refreshFollowed() async {
    if (_followedGames.isEmpty) return;
    List<Map<String, dynamic>> updated = [];
    String? droppedGameTitle;
    double droppedPrice = 0.0;

    for (var g in _followedGames) {
      try {
        final res = await http.get(Uri.parse(
            'https://www.cheapshark.com/api/1.0/games?id=${g['gameID']}'));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final deals = data['deals'] as List? ?? [];
          final cheapestEver = data['cheapestPriceEver'] as Map<String, dynamic>?;

          if (deals.isNotEmpty) {
            final best = deals.first;
            final prevPrice = double.tryParse(g['salePrice'].toString()) ?? 0.0;
            final currPrice = double.tryParse(best['price'].toString()) ?? 0.0;

            if (currPrice < prevPrice && prevPrice > 0) {
              droppedGameTitle = data['info']['title'];
              droppedPrice = currPrice;
            }

            updated.add({
              'gameID': g['gameID'],
              'title': data['info']['title'],
              'thumb': data['info']['thumb'],
              'salePrice': best['price'],
              'normalPrice': best['retailPrice'],
              'storeID': best['storeID'],
              'dealID': best['dealID'],
              'historicalLow': cheapestEver?['price'] ?? best['price'],
              'historicalDate': cheapestEver?['date'] ?? 0,
            });
            continue;
          }
        }
      } catch (_) {}
      updated.add(g);
    }

    setState(() => _followedGames = updated);
    _saveFollowed();

    if (droppedGameTitle != null && mounted) {
      _triggerNotificationWithSound(
        '🔥 ¡Oferta en $droppedGameTitle!',
        'El juego bajó a \$$droppedPrice en tiendas oficiales.',
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF141B26),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF00F5A0), width: 1.5),
          ),
          content: Row(
            children: [
              const Icon(Icons.notifications_active, color: Color(0xFF00F5A0)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '¡Nueva rebaja en "$droppedGameTitle" a \$$droppedPrice!',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _handleRefreshAll() async {
    await Future.wait([
      _fetchBinanceRate(),
      _fetchDeals(),
      _refreshFollowed(),
    ]);
  }

  void _showGameAllDealsModal(String gameID, String title, String thumb) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141B26),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return FutureBuilder<http.Response>(
          future: http.get(Uri.parse('https://www.cheapshark.com/api/1.0/games?id=$gameID')),
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const SizedBox(
                height: 280,
                child: Center(child: CircularProgressIndicator(color: Color(0xFF00D2FF))),
              );
            }

            final data = jsonDecode(snapshot.data!.body);
            final deals = (data['deals'] as List? ?? []).cast<Map<String, dynamic>>();
            final cheapestEver = data['cheapestPriceEver'] as Map<String, dynamic>?;

            final lowestPrice = cheapestEver?['price'] != null
                ? double.tryParse(cheapestEver!['price'].toString()) ?? 0.0
                : 0.0;
            final lowestDateRaw = cheapestEver?['date'] ?? 0;
            final lowestDateStr = lowestDateRaw > 0
                ? DateFormat('dd/MM/yyyy').format(DateTime.fromMillisecondsSinceEpoch(lowestDateRaw * 1000))
                : 'N/A';

            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          thumb,
                          width: 65,
                          height: 38,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.videogame_asset),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B0F17),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1F293D)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.history, color: Color(0xFF00F5A0), size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Mínimo histórico: \$${lowestPrice.toStringAsFixed(2)}',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                        Text(
                          '($lowestDateStr)',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Precios por tienda disponible:',
                    style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.42,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: deals.length,
                      separatorBuilder: (_, __) => const Divider(color: Color(0xFF1F293D)),
                      itemBuilder: (_, idx) {
                        final d = deals[idx];
                        final storeName = _storesMap[d['storeID'].toString()] ?? 'Tienda #${d['storeID']}';
                        final price = double.tryParse(d['price'].toString()) ?? 0.0;
                        final priceVes = price * _vesRate;
                        final retail = double.tryParse(d['retailPrice'].toString()) ?? 0.0;
                        final savings = double.tryParse(d['savings'].toString()) ?? 0.0;

                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(storeName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                          subtitle: Text(
                            'Bs. ${_currencyFormat.format(priceVes)}' +
                                (savings > 0 ? ' • Regular: \$$retail' : ''),
                            style: const TextStyle(color: Color(0xFF00F5A0), fontSize: 12),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '\$${price.toStringAsFixed(2)}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.open_in_new, color: Color(0xFF00D2FF), size: 20),
                                onPressed: () {
                                  final dealUrl = 'https://www.cheapshark.com/redirect?dealID=${d['dealID']}';
                                  launchUrl(Uri.parse(dealUrl), mode: LaunchMode.externalApplication);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openSearchModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141B26),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SearchGameModal(
        storesMap: _storesMap,
        vesRate: _vesRate,
        onSelectGame: (game) {
          final exists = _followedGames.any((g) => g['gameID'] == game['gameID']);
          if (!exists) {
            setState(() => _followedGames.add(game));
            _saveFollowed();
          }
          Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F17),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00D2FF).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.radar, color: Color(0xFF00D2FF), size: 24),
            ),
            const SizedBox(width: 10),
            const Text(
              'Radar Gamer',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Actualizar todo',
            onPressed: _handleRefreshAll,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF141B26),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1F293D)),
            ),
            child: Row(
              children: [
                const Icon(Icons.currency_exchange, color: Color(0xFFF0B90B), size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Binance P2P:',
                  style: TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                _isLoadingRate
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)),
                      )
                    : Text(
                        '1 USDT = Bs. ${_currencyFormat.format(_vesRate)}',
                        style: const TextStyle(
                          color: Color(0xFF00F5A0),
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const Text('Región:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: const Color(0xFF141B26),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF1F293D)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _saveRegion('LATAM'),
                            child: Container(
                              decoration: BoxDecoration(
                                color: _region == 'LATAM' ? const Color(0xFF00D2FF).withOpacity(0.2) : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                                border: _region == 'LATAM'
                                    ? Border.all(color: const Color(0xFF00D2FF), width: 1.5)
                                    : null,
                              ),
                              alignment: Alignment.center,
                              child: const Text(
                                '🇻🇪 LATAM-USD',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _saveRegion('USA'),
                            child: Container(
                              decoration: BoxDecoration(
                                color: _region == 'USA' ? const Color(0xFF00D2FF).withOpacity(0.2) : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                                border: _region == 'USA'
                                    ? Border.all(color: const Color(0xFF00D2FF), width: 1.5)
                                    : null,
                              ),
                              alignment: Alignment.center,
                              child: const Text(
                                '🇺🇸 USA (Global)',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFF00D2FF),
            labelColor: const Color(0xFF00D2FF),
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(
                icon: const Icon(Icons.bookmark_border, size: 20),
                text: 'Siguiendo (${_followedGames.length})',
              ),
              const Tab(
                icon: const Icon(Icons.local_fire_department, size: 20),
                text: 'Top Gangas',
              ),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                RefreshIndicator(
                  color: const Color(0xFF00D2FF),
                  backgroundColor: const Color(0xFF141B26),
                  onRefresh: _handleRefreshAll,
                  child: _followedGames.isEmpty
                      ? ListView(
                          children: const [
                            SizedBox(height: 120),
                            Center(
                              child: Column(
                                children: [
                                  Icon(Icons.sports_esports, size: 48, color: Colors.white24),
                                  SizedBox(height: 12),
                                  Text(
                                    'No tienes juegos en seguimiento',
                                    style: TextStyle(color: Colors.white54, fontSize: 15),
                                  ),
                                  SizedBox(height: 4),
                                  Text(
                                    'Usa el botón de abajo para buscar y agregar',
                                    style: TextStyle(color: Colors.white38, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 80, left: 12, right: 12),
                          itemCount: _followedGames.length,
                          itemBuilder: (ctx, i) {
                            final game = _followedGames[i];
                            return _buildGameCard(
                              title: game['title'] ?? '',
                              thumb: game['thumb'] ?? '',
                              salePrice: double.tryParse(game['salePrice'].toString()) ?? 0.0,
                              normalPrice: double.tryParse(game['normalPrice'].toString()) ?? 0.0,
                              storeID: game['storeID']?.toString() ?? '1',
                              dealID: game['dealID']?.toString() ?? '',
                              gameID: game['gameID']?.toString() ?? '',
                              historicalLow: double.tryParse(game['historicalLow']?.toString() ?? '0.0') ?? 0.0,
                              isFollowed: true,
                              onDelete: () {
                                setState(() => _followedGames.removeAt(i));
                                _saveFollowed();
                              },
                            );
                          },
                        ),
                ),
                RefreshIndicator(
                  color: const Color(0xFF00D2FF),
                  backgroundColor: const Color(0xFF141B26),
                  onRefresh: _handleRefreshAll,
                  child: _isLoadingDeals
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D2FF)))
                      : ListView.builder(
                          padding: const EdgeInsets.only(top: 8, bottom: 80, left: 12, right: 12),
                          itemCount: _deals.length,
                          itemBuilder: (ctx, i) {
                            final d = _deals[i];
                            return _buildGameCard(
                              title: d['title'] ?? '',
                              thumb: d['thumb'] ?? '',
                              salePrice: double.tryParse(d['salePrice'].toString()) ?? 0.0,
                              normalPrice: double.tryParse(d['normalPrice'].toString()) ?? 0.0,
                              storeID: d['storeID']?.toString() ?? '1',
                              dealID: d['dealID']?.toString() ?? '',
                              gameID: d['gameID']?.toString() ?? '',
                              historicalLow: 0.0,
                              isFollowed: false,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00D2FF),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.search, size: 20),
        label: const Text('Buscar y Seguir', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _openSearchModal,
      ),
    );
  }

  Widget _buildGameCard({
    required String title,
    required String thumb,
    required double salePrice,
    required double normalPrice,
    required String storeID,
    required String dealID,
    required String gameID,
    required double historicalLow,
    required bool isFollowed,
    VoidCallback? onDelete,
  }) {
    final storeName = _storesMap[storeID] ?? 'Tienda Autorizada';
    final priceVes = salePrice * _vesRate;
    final hasDiscount = normalPrice > salePrice;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          if (gameID.isNotEmpty) {
            _showGameAllDealsModal(gameID, title, thumb);
          } else {
            final url = 'https://www.cheapshark.com/redirect?dealID=$dealID';
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  thumb,
                  width: 80,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 80,
                    height: 48,
                    color: Colors.white10,
                    child: const Icon(Icons.broken_image, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      storeName,
                      style: const TextStyle(color: Color(0xFF00D2FF), fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Bs. ${_currencyFormat.format(priceVes)}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (isFollowed && historicalLow > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Mínimo hist.: \$$historicalLow',
                        style: const TextStyle(color: Color(0xFF00F5A0), fontSize: 10),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '\$${salePrice.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Color(0xFF00F5A0),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (hasDiscount)
                    Text(
                      '\$${normalPrice.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.storefront, color: Colors.white38, size: 16),
                      if (isFollowed && onDelete != null) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: onDelete,
                          child: const Icon(Icons.close, color: Colors.redAccent, size: 18),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SearchGameModal extends StatefulWidget {
  final Map<String, String> storesMap;
  final double vesRate;
  final Function(Map<String, dynamic>) onSelectGame;

  const SearchGameModal({
    super.key,
    required this.storesMap,
    required this.vesRate,
    required this.onSelectGame,
  });

  @override
  State<SearchGameModal> createState() => _SearchGameModalState();
}

class _SearchGameModalState extends State<SearchGameModal> {
  final TextEditingController _controller = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'es_VE');

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _searching = true);
    try {
      final res = await http.get(Uri.parse(
          'https://www.cheapshark.com/api/1.0/games?title=${Uri.encodeComponent(query)}&limit=15'));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        setState(() {
          _results = list.cast<Map<String, dynamic>>();
          _searching = false;
        });
        return;
      }
    } catch (_) {}
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Buscar juego (ej. Metal Gear, Far Cry)...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFF00D2FF)),
              suffixIcon: IconButton(
                icon: const Icon(Icons.send, color: Color(0xFF00D2FF)),
                onPressed: () => _search(_controller.text),
              ),
              filled: true,
              fillColor: const Color(0xFF0B0F17),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1F293D)),
              ),
            ),
            onSubmitted: _search,
          ),
          const SizedBox(height: 12),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(20),
              child: CircularProgressIndicator(color: Color(0xFF00D2FF)),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _results.length,
                separatorBuilder: (_, __) => const Divider(color: Color(0xFF1F293D)),
                itemBuilder: (ctx, i) {
                  final g = _results[i];
                  final price = double.tryParse(g['cheapest'].toString()) ?? 0.0;
                  final priceVes = price * widget.vesRate;

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        g['thumb'] ?? '',
                        width: 50,
                        height: 30,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.videogame_asset),
                      ),
                    ),
                    title: Text(g['external'] ?? '', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      'Mejor precio: \$$price (Bs. ${_currencyFormat.format(priceVes)})',
                      style: const TextStyle(color: Color(0xFF00F5A0), fontSize: 11),
                    ),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00D2FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      ),
                      onPressed: () {
                        widget.onSelectGame({
                          'gameID': g['gameID'],
                          'title': g['external'],
                          'thumb': g['thumb'],
                          'salePrice': g['cheapest'],
                          'normalPrice': g['cheapest'],
                          'storeID': '1',
                          'dealID': g['cheapestDealID'],
                          'historicalLow': g['cheapest'],
                        });
                      },
                      child: const Text('Seguir', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}