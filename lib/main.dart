import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const GameDealRadarApp());
}

/* ==========================================================================
   MODELOS DE DATOS
   ========================================================================== */

class GameItem {
  final String gameID;
  final String? steamAppID;
  final String title;
  final String thumb;
  double priceUSD;
  double retailUSD;
  double historicalLowUSD;
  String store;
  String? dealID;

  GameItem({
    required this.gameID,
    this.steamAppID,
    required this.title,
    required this.thumb,
    this.priceUSD = 0.0,
    this.retailUSD = 0.0,
    this.historicalLowUSD = 0.0,
    this.store = "Buscando...",
    this.dealID,
  });

  Map<String, dynamic> toMap() => {
    'gameID': gameID,
    'steamAppID': steamAppID,
    'title': title,
    'thumb': thumb,
  };

  factory GameItem.fromMap(Map<String, dynamic> map) => GameItem(
    gameID: map['gameID'] ?? '',
    steamAppID: map['steamAppID'],
    title: map['title'] ?? '',
    thumb: map['thumb'] ?? '',
  );

  String toJson() => jsonEncode(toMap());
  factory GameItem.fromJson(String source) => GameItem.fromMap(jsonDecode(source));
}

/* ==========================================================================
   SERVICIO DE APIs (CheapShark + Binance P2P + Steam Regional)
   ========================================================================== */

class ApiService {
  static const Map<String, String> storeNames = {
    "1": "Steam",
    "2": "GamersGate",
    "3": "Green Man Gaming",
    "7": "GOG",
    "11": "Humble Store",
    "15": "Fanatical",
    "25": "Epic Games",
  };

  // Promedia 5 anuncios tras descartar el 1ro (compra de USDT)
  static Future<double> fetchBinanceP2PRate() async {
    const url = 'https://p2p.binance.com/bapi/c2c/v2/friendly/c2c/adv/search';
    final payload = {
      "fiat": "VES",
      "page": 1,
      "rows": 7,
      "tradeType": "BUY",
      "asset": "USDT",
      "proMerchantAds": false
    };

    try {
      final res = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body)['data'] ?? [];
        if (data.length > 1) {
          final sampleAds = data.skip(1).take(5).toList();
          double sum = 0.0;
          int count = 0;

          for (var ad in sampleAds) {
            final price = double.tryParse(ad['adv']?['price']?.toString() ?? '');
            if (price != null && price > 0) {
              sum += price;
              count++;
            }
          }

          if (count > 0) {
            return sum / count;
          }
        }
      }
    } catch (_) {}
    return 950.0;
  }

  // Búsqueda en catálogo
  static Future<List<Map<String, dynamic>>> searchGames(String query) async {
    if (query.trim().isEmpty) return [];
    final url = 'https://www.cheapshark.com/api/1.0/games?title=${Uri.encodeComponent(query)}&limit=15';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        return list.map<Map<String, dynamic>>((item) => {
          'gameID': item['gameID'].toString(),
          'steamAppID': item['steamAppID']?.toString(),
          'title': item['external'],
          'cheapest': double.tryParse(item['cheapest'].toString()) ?? 0.0,
          'thumb': item['thumb'] ?? '',
        }).toList();
      }
    } catch (_) {}
    return [];
  }

  // Detalles, récords y precio según región
  static Future<Map<String, dynamic>?> fetchGameDetails(String gameID, {String region = 've'}) async {
    final url = 'https://www.cheapshark.com/api/1.0/games?id=$gameID';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final deals = data['deals'] as List?;
        final cheapestEver = data['cheapestPriceEver']?['price'];
        final double histLow = double.tryParse(cheapestEver?.toString() ?? '0') ?? 0.0;

        if (deals != null && deals.isNotEmpty) {
          final bestDeal = deals.first;
          final storeId = bestDeal['storeID']?.toString() ?? "1";
          
          double currentPrice = double.tryParse(bestDeal['price'].toString()) ?? 0.0;
          double retailPrice = double.tryParse(bestDeal['retailPrice'].toString()) ?? 0.0;
          String storeName = storeNames[storeId] ?? "Tienda Autorizada";
          String dealID = bestDeal['dealID'];

          final steamAppID = data['info']?['steamAppID']?.toString();
          if (steamAppID != null && steamAppID.isNotEmpty) {
            final steamPrice = await fetchSteamRegional(steamAppID, region);
            if (steamPrice != null) {
              if (region == 've' && steamPrice <= currentPrice) {
                currentPrice = steamPrice;
                storeName = "Steam (LATAM-USD)";
              } else if (region == 'us' && storeId == "1") {
                currentPrice = steamPrice;
                storeName = "Steam (USA)";
              }
            }
          }

          return {
            'priceUSD': currentPrice,
            'retailUSD': retailPrice,
            'historicalLowUSD': histLow,
            'store': storeName,
            'dealID': dealID,
          };
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<double?> fetchSteamRegional(String steamAppId, String countryCode) async {
    final url = 'https://store.steampowered.com/api/appdetails?appids=$steamAppId&cc=$countryCode&filters=price_overview';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data[steamAppId]?['success'] == true) {
          final p = data[steamAppId]['data']['price_overview'];
          if (p != null) {
            return (p['final'] as num) / 100.0;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> fetchTopDeals() async {
    const url = 'https://www.cheapshark.com/api/1.0/deals?dealRating=9.0&pageSize=15';
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        return list.map<Map<String, dynamic>>((d) {
          final storeId = d['storeID']?.toString() ?? "1";
          return {
            'title': d['title'],
            'salePrice': double.parse(d['salePrice'].toString()),
            'normalPrice': double.parse(d['normalPrice'].toString()),
            'savings': double.parse(d['savings'].toString()).toStringAsFixed(0),
            'thumb': d['thumb'],
            'dealID': d['dealID'],
            'store': storeNames[storeId] ?? "Tienda Autorizada",
          };
        }).toList();
      }
    } catch (_) {}
    return [];
  }
}

/* ==========================================================================
   APP SHELL Y TEMAS
   ========================================================================== */

class GameDealRadarApp extends StatelessWidget {
  const GameDealRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Radar Gamer',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00D2FF),
          secondary: Color(0xFF00E676),
          surface: Color(0xFF141B26),
          onSurface: Colors.white,
        ),
	cardTheme: const CardThemeData(
          color: Color(0xFF141B26),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
            side: BorderSide(color: Color(0xFF1F293D), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0E17),
          elevation: 0,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

/* ==========================================================================
   PANTALLA PRINCIPAL
   ========================================================================== */

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  double _vesRate = 950.0;
  bool _isLoading = true;
  bool _isSwitchingRegion = false;
  String _selectedRegion = 've';

  List<GameItem> _watchlist = [];
  final Set<String> _cartGameIDs = {};
  List<Map<String, dynamic>> _topDeals = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initApp();
  }

  Future<void> _initApp() async {
    setState(() => _isLoading = true);
    await _loadStoredWatchlist();
    _vesRate = await ApiService.fetchBinanceP2PRate();
    await _refreshWatchlistPrices();
    _topDeals = await ApiService.fetchTopDeals();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadStoredWatchlist() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList('radar_watchlist') ?? [];
    _watchlist = data.map((str) => GameItem.fromJson(str)).toList();
  }

  Future<void> _saveWatchlist() async {
    final prefs = await SharedPreferences.getInstance();
    final data = _watchlist.map((g) => g.toJson()).toList();
    await prefs.setStringList('radar_watchlist', data);
  }

  Future<void> _refreshWatchlistPrices() async {
    for (final game in _watchlist) {
      final details = await ApiService.fetchGameDetails(game.gameID, region: _selectedRegion);
      if (details != null) {
        game.priceUSD = details['priceUSD'];
        game.retailUSD = details['retailUSD'];
        game.historicalLowUSD = details['historicalLowUSD'];
        game.store = details['store'];
        game.dealID = details['dealID'];
      }
    }
  }

  void _onRegionChanged(String newRegion) async {
    if (_selectedRegion == newRegion) return;
    setState(() {
      _selectedRegion = newRegion;
      _isSwitchingRegion = true;
    });

    await _refreshWatchlistPrices();

    if (mounted) {
      setState(() => _isSwitchingRegion = false);
    }
  }

  void _addGameToWatchlist(GameItem game) async {
    if (_watchlist.any((g) => g.gameID == game.gameID)) return;
    setState(() => _watchlist.add(game));
    await _saveWatchlist();

    final details = await ApiService.fetchGameDetails(game.gameID, region: _selectedRegion);
    if (details != null && mounted) {
      setState(() {
        game.priceUSD = details['priceUSD'];
        game.retailUSD = details['retailUSD'];
        game.historicalLowUSD = details['historicalLowUSD'];
        game.store = details['store'];
        game.dealID = details['dealID'];
      });
    }
  }

  void _removeGame(int index) async {
    final removed = _watchlist.removeAt(index);
    _cartGameIDs.remove(removed.gameID);
    setState(() {});
    await _saveWatchlist();
  }

  void _toggleCart(String gameID) {
    setState(() {
      if (_cartGameIDs.contains(gameID)) {
        _cartGameIDs.remove(gameID);
      } else {
        _cartGameIDs.add(gameID);
      }
    });
  }

  Future<void> _openDeal(String? dealID) async {
    if (dealID == null) return;
    final uri = Uri.parse("https://www.cheapshark.com/redirect?dealID=$dealID");
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _showCartSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101622),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            final cartGames = _watchlist.where((g) => _cartGameIDs.contains(g.gameID)).toList();
            final double totalUSD = cartGames.fold<double>(0.0, (acc, item) => acc + item.priceUSD);
            final double totalVES = totalUSD * _vesRate;
            final currencyFormatter = NumberFormat("#,##0.00", "es_VE");

            final Map<String, List<GameItem>> byStore = {};
            for (var g in cartGames) {
              byStore.putIfAbsent(g.store, () => []).add(g);
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.shopping_cart_checkout, color: Color(0xFF00D2FF)),
                          const SizedBox(width: 8),
                          Text("Simulador (${cartGames.length})", style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white)),
                        ],
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () async {
                          final newRate = await ApiService.fetchBinanceP2PRate();
                          setModalState(() => _vesRate = newRate);
                          setState(() => _vesRate = newRate);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E232D),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF00D2FF).withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.sync, size: 13, color: Color(0xFFF3BA2F)),
                              const SizedBox(width: 4),
                              Text(
                                "Bs. ${currencyFormatter.format(_vesRate)}",
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFF3BA2F)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Color(0xFF1F293D), height: 20),

                  if (cartGames.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          "No has agregado juegos al simulador.\nToca el carrito en tu lista para sumar juegos.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ),
                    )
                  else ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: cartGames.length,
                        separatorBuilder: (_, __) => const Divider(color: Color(0xFF17202F), height: 12),
                        itemBuilder: (context, i) {
                          final g = cartGames[i];
                          final double gVes = g.priceUSD * _vesRate;
                          return Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.network(
                                  g.thumb,
                                  width: 44,
                                  height: 26,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(width: 44, height: 26, color: Colors.white10),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      g.title,
                                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      g.store,
                                      style: const TextStyle(color: Color(0xFF00D2FF), fontSize: 10),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    "\$${g.priceUSD.toStringAsFixed(2)} USDT",
                                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    "Bs. ${currencyFormatter.format(gVes)}",
                                    style: const TextStyle(color: Colors.grey, fontSize: 10),
                                  ),
                                ],
                              ),
                              IconButton(
                                icon: const Icon(Icons.close, size: 16, color: Colors.white30),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () {
                                  setModalState(() => _cartGameIDs.remove(g.gameID));
                                  setState(() => _cartGameIDs.remove(g.gameID));
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 12),
                    const Text("Subtotales por Plataforma:", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),

                    ...byStore.entries.map((entry) {
                      final subUSD = entry.value.fold<double>(0.0, (acc, g) => acc + g.priceUSD);
                      final subVES = subUSD * _vesRate;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("• ${entry.key} (${entry.value.length})", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            Text(
                              "\$${subUSD.toStringAsFixed(2)} USDT  (~Bs. ${currencyFormatter.format(subVES)})",
                              style: const TextStyle(color: Color(0xFF00D2FF), fontSize: 11, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      );
                    }),

                    const SizedBox(height: 12),

                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141C2B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF00D2FF).withOpacity(0.25)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Total Estimado (Cripto):", style: TextStyle(fontSize: 13, color: Colors.white70)),
                              Text(
                                "\$${totalUSD.toStringAsFixed(2)} USDT",
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF00E676)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Equivalente en Bolívares:", style: TextStyle(fontSize: 12, color: Colors.grey)),
                              Text(
                                "Bs. ${currencyFormatter.format(totalVES)}",
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFF3BA2F)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openSearchSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101622),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => _SearchModal(
        onSelected: (game) {
          _addGameToWatchlist(game);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currencyFormatter = NumberFormat("#,##0.00", "es_VE");

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.radar, color: Color(0xFF00D2FF)),
            SizedBox(width: 8),
            Text('Radar Gamer'),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF141B26),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1F293D)),
            ),
            child: Row(
              children: [
                const Text("P2P: ", style: TextStyle(fontSize: 10, color: Colors.grey)),
                Text(
                  "Bs. ${currencyFormatter.format(_vesRate)}",
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFF3BA2F)),
                ),
              ],
            ),
          ),
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.shopping_cart_outlined, color: Colors.white),
                onPressed: _showCartSheet,
              ),
              if (_cartGameIDs.isNotEmpty)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Color(0xFF00E676), shape: BoxShape.circle),
                    child: Text(
                      "${_cartGameIDs.length}",
                      style: const TextStyle(fontSize: 10, color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 6),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(98),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Row(
                  children: [
                    const Text("Región:", style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 34,
                        decoration: BoxDecoration(
                          color: const Color(0xFF141B26),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF1F293D)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => _onRegionChanged('ve'),
                                borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)),
                                child: Container(
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _selectedRegion == 've' ? const Color(0xFF00D2FF).withOpacity(0.18) : Colors.transparent,
                                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)),
                                  ),
                                  child: Text(
                                    "🇻🇪 LATAM-USD",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: _selectedRegion == 've' ? FontWeight.bold : FontWeight.normal,
                                      color: _selectedRegion == 've' ? const Color(0xFF00D2FF) : Colors.white60,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Container(width: 1, color: const Color(0xFF1F293D)),
                            Expanded(
                              child: InkWell(
                                onTap: () => _onRegionChanged('us'),
                                borderRadius: const BorderRadius.horizontal(right: Radius.circular(9)),
                                child: Container(
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _selectedRegion == 'us' ? const Color(0xFF00D2FF).withOpacity(0.18) : Colors.transparent,
                                    borderRadius: const BorderRadius.horizontal(right: Radius.circular(9)),
                                  ),
                                  child: Text(
                                    "🇺🇸 USA (Global)",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: _selectedRegion == 'us' ? FontWeight.bold : FontWeight.normal,
                                      color: _selectedRegion == 'us' ? const Color(0xFF00D2FF) : Colors.white60,
                                    ),
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
                  Tab(icon: const Icon(Icons.bookmark_border_rounded), text: "Siguiendo (${_watchlist.length})"),
                  const Tab(icon: Icon(Icons.local_fire_department_rounded), text: "Top Gangas"),
                ],
              ),
            ],
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D2FF)))
          : Stack(
              children: [
                TabBarView(
                  controller: _tabController,
                  children: [
                    _buildWatchlistTab(currencyFormatter),
                    _buildTopDealsTab(currencyFormatter),
                  ],
                ),
                if (_isSwitchingRegion)
                  Container(
                    color: Colors.black.withOpacity(0.3),
                    child: const Center(
                      child: CircularProgressIndicator(color: Color(0xFF00D2FF)),
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF00D2FF),
        foregroundColor: const Color(0xFF0A0E17),
        icon: const Icon(Icons.search_rounded),
        label: const Text("Buscar y Seguir", style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _openSearchSheet,
      ),
    );
  }

  Widget _buildWatchlistTab(NumberFormat currencyFormatter) {
    if (_watchlist.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sports_esports_outlined, size: 72, color: Colors.white.withOpacity(0.15)),
            const SizedBox(height: 12),
            const Text("No tienes videojuegos en seguimiento", style: TextStyle(color: Colors.white70, fontSize: 15)),
            const SizedBox(height: 4),
            const Text("Usa 'Buscar y Seguir' para agregar títulos", style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      itemCount: _watchlist.length,
      itemBuilder: (context, index) {
        final game = _watchlist[index];
        final isInCart = _cartGameIDs.contains(game.gameID);
        final isHistoricLow = game.priceUSD > 0 && game.priceUSD <= game.historicalLowUSD;
        final double priceVES = game.priceUSD * _vesRate;

        return Dismissible(
          key: Key(game.gameID),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.8), borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.delete_outline, color: Colors.white),
          ),
          onDismissed: (_) => _removeGame(index),
          child: Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openDeal(game.dealID),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        game.thumb,
                        width: 85,
                        height: 50,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(width: 85, height: 50, color: const Color(0xFF1E2638), child: const Icon(Icons.image_not_supported, size: 18)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            game.title,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: const Color(0xFF1E293D), borderRadius: BorderRadius.circular(6)),
                                child: Text(game.store, style: const TextStyle(fontSize: 10, color: Color(0xFF00D2FF))),
                              ),
                              if (isHistoricLow) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(color: const Color(0xFF00E676).withOpacity(0.15), borderRadius: BorderRadius.circular(6)),
                                  child: const Text("MÍNIMO", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF00E676))),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          game.priceUSD > 0 ? "\$${game.priceUSD.toStringAsFixed(2)}" : "--",
                          style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        if (game.priceUSD > 0)
                          Text("Bs. ${currencyFormatter.format(priceVES)}", style: const TextStyle(fontSize: 10, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: Icon(
                        isInCart ? Icons.check_circle_rounded : Icons.add_shopping_cart_rounded,
                        color: isInCart ? const Color(0xFF00E676) : Colors.white30,
                        size: 22,
                      ),
                      onPressed: () => _toggleCart(game.gameID),
                    )
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopDealsTab(NumberFormat currencyFormatter) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      itemCount: _topDeals.length,
      itemBuilder: (context, i) {
        final item = _topDeals[i];
        final double sale = item['salePrice'];
        final double normal = item['normalPrice'];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openDeal(item['dealID']),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(item['thumb'], width: 85, height: 50, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item['title'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                              child: Text("-${item['savings']}%", style: const TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(width: 6),
                            Text(item['store'], style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          ],
                        )
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text("\$${normal.toStringAsFixed(2)}", style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey, fontSize: 10)),
                      Text("\$${sale.toStringAsFixed(2)}", style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 15)),
                      Text("Bs. ${currencyFormatter.format(sale * _vesRate)}", style: const TextStyle(fontSize: 10, color: Colors.grey)),
                    ],
                  )
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/* ==========================================================================
   MODAL DE BÚSQUEDA INTERACTIVA
   ========================================================================== */

class _SearchModal extends StatefulWidget {
  final Function(GameItem) onSelected;
  const _SearchModal({required this.onSelected});

  @override
  State<_SearchModal> createState() => _SearchModalState();
}

class _SearchModalState extends State<_SearchModal> {
  final TextEditingController _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;

  void _executeSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _searching = true);
    final list = await ApiService.searchGames(query);
    if (mounted) setState(() {
      _results = list;
      _searching = false;
    });
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
      child: SizedBox(
        height: 520,
        child: Column(
          children: [
            TextField(
              controller: _ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Buscar juego (ej: Alice, Resident Evil, MGS)...",
                hintStyle: const TextStyle(color: Colors.grey),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00D2FF)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded, color: Color(0xFF00D2FF)),
                  onPressed: () => _executeSearch(_ctrl.text),
                ),
                filled: true,
                fillColor: const Color(0xFF141B26),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
              onSubmitted: _executeSearch,
            ),
            const SizedBox(height: 12),
            if (_searching)
              const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: Color(0xFF00D2FF)))
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (ctx, i) {
                    final item = _results[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(item['thumb'], width: 52, height: 32, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.videogame_asset)),
                      ),
                      title: Text(item['title'], style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white), maxLines: 1),
                      subtitle: Text("Precio base más bajo: \$${item['cheapest']}", style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      trailing: IconButton(
                        icon: const Icon(Icons.add_circle, color: Color(0xFF00D2FF)),
                        onPressed: () {
                          final g = GameItem(
                            gameID: item['gameID'],
                            steamAppID: item['steamAppID'],
                            title: item['title'],
                            thumb: item['thumb'],
                          );
                          widget.onSelected(g);
                        },
                      ),
                    );
                  },
                ),
              )
          ],
        ),
      ),
    );
  }
}