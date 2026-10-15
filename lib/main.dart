import 'dart:async';
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
const String dealsChannelId = "deals_channel";
const String dealsChannelName = "Alertas de Ofertas";
const String dealsChannelDesc = "Notificaciones cuando bajan de precio los juegos seguidos";

const AndroidNotificationChannel dealsNotificationChannel = AndroidNotificationChannel(
  dealsChannelId,
  dealsChannelName,
  description: dealsChannelDesc,
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // 1. Inicializar notificaciones dentro del isolate en segundo plano
      final FlutterLocalNotificationsPlugin bgNotificationsPlugin =
          FlutterLocalNotificationsPlugin();
      const AndroidInitializationSettings initAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const InitializationSettings initSettings =
          InitializationSettings(android: initAndroid);
      await bgNotificationsPlugin.initialize(initSettings);

      // 2. Crear formalmente el canal de notificaciones a nivel de sistema Android
      final androidPlatformPlugin = bgNotificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlatformPlugin != null) {
        await androidPlatformPlugin.createNotificationChannel(dealsNotificationChannel);
      }

      // 3. Cargar juegos en seguimiento
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // Forzar lectura de disco actualizada
      final savedStr = prefs.getString('followed_games_list');
      if (savedStr == null || savedStr.isEmpty) return Future.value(true);

      final List followed = jsonDecode(savedStr);
      if (followed.isEmpty) return Future.value(true);

      bool hadPriceChanges = false;

      // Extraer IDs válidos para consulta por lote
      final validGameIDs = followed
          .map((g) => g['gameID']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .cast<String>()
          .toList();

      if (validGameIDs.isEmpty) return Future.value(true);

      const int batchSize = 25;
      final Map<String, dynamic> allBatchData = {};

      for (int i = 0; i < validGameIDs.length; i += batchSize) {
        final chunk = validGameIDs.sublist(
          i,
          (i + batchSize > validGameIDs.length) ? validGameIDs.length : i + batchSize,
        );

        try {
          final res = await http.get(
            Uri.parse('https://www.cheapshark.com/api/1.0/games?ids=${chunk.join(',')}'),
            headers: {'Accept': 'application/json', 'User-Agent': 'RadarGamerApp/1.0'},
          ).timeout(const Duration(seconds: 15));

          if (res.statusCode == 200) {
            final Map<String, dynamic> batchResult = jsonDecode(res.body);
            allBatchData.addAll(batchResult);
          }
        } catch (_) {}
      }

      for (int i = 0; i < followed.length; i++) {
        final g = followed[i];
        final gameId = g['gameID']?.toString();
        if (gameId == null || !allBatchData.containsKey(gameId)) continue;

        try {
          final gameData = allBatchData[gameId];
          final deals = (gameData['deals'] as List? ?? []).cast<Map<String, dynamic>>();
          final info = gameData['info'] as Map<String, dynamic>? ?? {};

          if (deals.isNotEmpty) {
            deals.sort((a, b) {
              final pA = double.tryParse(a['price'].toString()) ?? double.infinity;
              final pB = double.tryParse(b['price'].toString()) ?? double.infinity;
              return pA.compareTo(pB);
            });

            final best = deals.first;
            final prevPrice = double.tryParse(g['salePrice'].toString()) ?? 0.0;
            final currPrice = double.tryParse(best['price'].toString()) ?? 0.0;

            // Registrar en historial si hubo cambio de precio
            if (currPrice != prevPrice) {
              final history = List<dynamic>.from(g['priceHistory'] ?? []);
              history.add({
                'price': currPrice,
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              });
              followed[i]['priceHistory'] = history;
              followed[i]['salePrice'] = currPrice.toStringAsFixed(2);
              hadPriceChanges = true;
            }

            // Si bajó de precio con respecto a la última consulta
            if (currPrice < prevPrice && prevPrice > 0) {
              const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
                dealsChannelId,
                dealsChannelName,
                channelDescription: dealsChannelDesc,
                importance: Importance.max,
                priority: Priority.high,
                playSound: true,
                enableVibration: true,
                icon: '@mipmap/ic_launcher',
              );
              const NotificationDetails platformDetails =
                  NotificationDetails(android: androidDetails);

              final int notificationId =
                  DateTime.now().millisecondsSinceEpoch.remainder(100000);
              final title = info['title'] ?? g['title'] ?? 'Juego en seguimiento';
              await bgNotificationsPlugin.show(
                notificationId,
                '🔥 ¡Oferta en $title!',
                'Bajó a \$${currPrice.toStringAsFixed(2)} en tienda oficial',
                platformDetails,
              );
            }
          }
        } catch (_) {}
      }

      if (hadPriceChanges) {
        await prefs.setString('followed_games_list', jsonEncode(followed));
      }
    } catch (_) {}
    return Future.value(true);
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar plugin principal en primer plano
  const AndroidInitializationSettings initAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings =
      InitializationSettings(android: initAndroid);
  await flutterLocalNotificationsPlugin.initialize(initSettings);

  // Crear canal principal en Android
  final androidImpl = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  if (androidImpl != null) {
    await androidImpl.createNotificationChannel(dealsNotificationChannel);
  }

  // Inicializar Workmanager
  Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false,
  );

  // Registrar tarea periódica cada 4 horas
  Workmanager().registerPeriodicTask(
    "com.radargamer.dealCheckTask",
    periodicTaskName,
    frequency: const Duration(hours: 4),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(
      networkType: NetworkType.connected,
      requiresBatteryNotLow: false,
      requiresCharging: false,
      requiresDeviceIdle: false,
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
  bool _isRateFromCache = false;
  String _region = 'LATAM'; // 'LATAM' => cc=ve, 'USA' => cc=us
  Map<String, String> _storesMap = {};

  List<Map<String, dynamic>> _followedGames = [];
  String _followedSortOption = 'price_asc'; // 'price_asc', 'price_desc', 'title', 'recent'

  List<Map<String, dynamic>> _deals = [];
  bool _isLoadingDeals = true;

  List<Map<String, dynamic>> _freebies = [];
  bool _isLoadingFreebies = true;

  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'es_VE');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _requestNotificationPermissions();
    _initializeData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _requestNotificationPermissions() async {
    final androidImpl = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
  }

  Future<void> _initializeData() async {
    await _loadLocalSettings();
    await _loadStores();
    await Future.wait([
      _fetchBinanceRate(),
      _fetchDeals(),
      _fetchFreebies(),
    ]);
    // Refresco secuencial suave de juegos seguidos tras 1.5s de iniciar la app para evitar ráfagas
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) _refreshFollowed();
    });
  }

  Future<void> _loadStores() async {
    final Map<String, String> defaultMap = {
      '1': 'Steam',
      '2': 'GamersGate',
      '3': 'GreenManGaming',
      '7': 'GOG',
      '11': 'Humble Store',
      '15': 'Fanatical',
      '25': 'Epic Games Store',
      '31': 'Blizzard Shop',
    };

    final prefs = await SharedPreferences.getInstance();
    final cachedStr = prefs.getString('cached_stores_json');
    final lastFetch = prefs.getInt('cached_stores_time') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (cachedStr != null && cachedStr.isNotEmpty) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(cachedStr);
        final Map<String, String> map = decoded.map((k, v) => MapEntry(k, v.toString()));
        if (mounted) setState(() => _storesMap = map);
      } catch (_) {}
    } else {
      if (mounted) setState(() => _storesMap = defaultMap);
    }

    // Solo consultar a CheapShark si la caché tiene más de 7 días (o si no hay tiendas)
    final bool isStale = (now - lastFetch) > (7 * 24 * 60 * 60 * 1000);
    if (!isStale && _storesMap.isNotEmpty) return;

    try {
      final res = await http
          .get(
            Uri.parse('https://www.cheapshark.com/api/1.0/stores'),
            headers: {'Accept': 'application/json', 'User-Agent': 'RadarGamerApp/1.0'},
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        final Map<String, String> map = {};
        for (var s in list) {
          map[s['storeID'].toString()] = s['storeName'].toString();
        }
        await prefs.setString('cached_stores_json', jsonEncode(map));
        await prefs.setInt('cached_stores_time', now);
        if (mounted) setState(() => _storesMap = map);
      }
    } catch (_) {}
  }

  Future<void> _loadLocalSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _region = prefs.getString('saved_region') ?? 'LATAM';
        _followedSortOption = prefs.getString('followed_sort_option') ?? 'price_asc';
        final cachedRate = prefs.getDouble('last_known_ves_rate');
        if (cachedRate != null && cachedRate > 0) {
          _vesRate = cachedRate;
          _isRateFromCache = true;
        }
        final savedFollowed = prefs.getString('followed_games_list');
        if (savedFollowed != null) {
          final List raw = jsonDecode(savedFollowed);
          _followedGames = raw.map((item) {
            final map = Map<String, dynamic>.from(item);
            if (map['priceHistory'] == null) {
              final initialPrice = double.tryParse(map['salePrice'].toString()) ?? 0.0;
              map['priceHistory'] = [
                {
                  'price': initialPrice,
                  'timestamp': DateTime.now().millisecondsSinceEpoch,
                }
              ];
            }
            return map;
          }).toList();
        }
      });
    }
  }

  Future<void> _saveFollowed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('followed_games_list', jsonEncode(_followedGames));
  }

  Future<void> _saveSortOption(String sortOpt) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('followed_sort_option', sortOpt);
    if (mounted) setState(() => _followedSortOption = sortOpt);
  }

  Future<void> _saveRegion(String region) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_region', region);
    if (mounted) setState(() => _region = region);
    _handleRefreshAll();
  }

  Future<void> _fetchBinanceRate() async {
    if (mounted) setState(() => _isLoadingRate = true);
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

      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': 'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Mobile Safari/537.36',
              'Accept': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

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
            final avgRate = total / count;
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble('last_known_ves_rate', avgRate);
            if (mounted) {
              setState(() {
                _vesRate = avgRate;
                _isRateFromCache = false;
                _isLoadingRate = false;
              });
            }
            return;
          }
        }
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final cachedRate = prefs.getDouble('last_known_ves_rate');
    if (mounted) {
      setState(() {
        if (cachedRate != null && cachedRate > 0) {
          _vesRate = cachedRate;
          _isRateFromCache = true;
        } else if (_vesRate == 0.0) {
          _vesRate = 1015.00;
        }
        _isLoadingRate = false;
      });
    }
  }

  Future<void> _fetchDeals() async {
    final prefs = await SharedPreferences.getInstance();
    // 1. Mostrar de inmediato el feed guardado en disco si existe
    if (_deals.isEmpty) {
      final cachedStr = prefs.getString('cached_deals_feed');
      if (cachedStr != null && cachedStr.isNotEmpty) {
        try {
          final List list = jsonDecode(cachedStr);
          if (mounted) {
            setState(() {
              _deals = list.cast<Map<String, dynamic>>();
              _isLoadingDeals = false;
            });
          }
        } catch (_) {}
      }
    }

    try {
      final res = await http
          .get(
            Uri.parse(
                'https://www.cheapshark.com/api/1.0/deals?storeID=1,2,3,7,11,25,31&pageSize=35&sortBy=Deal%20Rating'),
            headers: {'Accept': 'application/json', 'User-Agent': 'RadarGamerApp/1.0'},
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        await prefs.setString('cached_deals_feed', res.body);
        if (mounted) {
          setState(() {
            _deals = list.cast<Map<String, dynamic>>();
            _isLoadingDeals = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingDeals = false);
  }

  Future<void> _fetchFreebies() async {
    if (mounted) setState(() => _isLoadingFreebies = true);
    try {
      final res = await http
          .get(Uri.parse('https://www.gamerpower.com/api/giveaways?type=game'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        if (mounted) {
          setState(() {
            _freebies = list.cast<Map<String, dynamic>>();
            _isLoadingFreebies = false;
          });
        }
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _isLoadingFreebies = false);
  }

  Future<Map<String, dynamic>?> _fetchSteamDetails(String steamAppID) async {
    try {
      final countryCode = _region == 'LATAM' ? 've' : 'us';
      final url = Uri.parse(
          'https://store.steampowered.com/api/appdetails?appids=$steamAppID&cc=$countryCode');
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data[steamAppID]?['success'] == true) {
          final gameData = data[steamAppID]['data'];
          final priceOverview = gameData['price_overview'];
          final dlcs = (gameData['dlc'] as List?)?.cast<int>() ?? [];

          double finalPrice = 0.0;
          double regularPrice = 0.0;
          int discount = 0;

          if (priceOverview != null) {
            finalPrice = (priceOverview['final'] as int? ?? 0) / 100.0;
            regularPrice = (priceOverview['initial'] as int? ?? 0) / 100.0;
            discount = priceOverview['discount_percent'] as int? ?? 0;
          }

          return {
            'price': finalPrice,
            'regular': regularPrice,
            'discount': discount,
            'dlc_ids': dlcs,
          };
        }
      }
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchSteamDlcs(List<int> dlcIds) async {
    if (dlcIds.isEmpty) return [];
    final countryCode = _region == 'LATAM' ? 've' : 'us';
    final topDlcs = dlcIds.take(5).toList();

    final futures = topDlcs.map((id) async {
      try {
        final url = Uri.parse(
            'https://store.steampowered.com/api/appdetails?appids=$id&cc=$countryCode&filters=basic,price_overview');
        final res = await http.get(url).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          if (data['$id']?['success'] == true) {
            final item = data['$id']['data'];
            final po = item['price_overview'];
            if (po != null) {
              return {
                'id': id,
                'name': item['name'] ?? 'DLC #$id',
                'price': (po['final'] as int? ?? 0) / 100.0,
                'regular': (po['initial'] as int? ?? 0) / 100.0,
                'discount': po['discount_percent'] as int? ?? 0,
              };
            }
          }
        }
      } catch (_) {}
      return null;
    });

    final results = await Future.wait(futures);
    return results.whereType<Map<String, dynamic>>().toList();
  }

  void _triggerNotificationWithSound(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      dealsChannelId,
      dealsChannelName,
      channelDescription: dealsChannelDesc,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const NotificationDetails platformDetails = NotificationDetails(android: androidDetails);
    await flutterLocalNotificationsPlugin.show(
      DateTime.now().millisecondsSinceEpoch.remainder(100000),
      title,
      body,
      platformDetails,
    );
  }

  bool _isRefreshingFollowed = false;

  Future<void> _refreshFollowed() async {
    if (_followedGames.isEmpty || _isRefreshingFollowed) return;
    _isRefreshingFollowed = true;

    String? droppedGameTitle;
    double droppedPrice = 0.0;
    List<Map<String, dynamic>> updatedList = List.from(_followedGames);
    bool anyChanged = false;

    // Extraer IDs válidos para consulta por lote (Batch Lookup oficial)
    final validGameIDs = updatedList
        .map((g) => g['gameID']?.toString())
        .where((id) => id != null && id.isNotEmpty)
        .cast<String>()
        .toList();

    if (validGameIDs.isEmpty) {
      _isRefreshingFollowed = false;
      return;
    }

    // Dividir en bloques de máximo 25 juegos (1 sola petición HTTP para hasta 25 juegos)
    const int batchSize = 25;
    final Map<String, dynamic> allBatchData = {};

    for (int i = 0; i < validGameIDs.length; i += batchSize) {
      final chunk = validGameIDs.sublist(
        i,
        (i + batchSize > validGameIDs.length) ? validGameIDs.length : i + batchSize,
      );

      try {
        final res = await http.get(
          Uri.parse('https://www.cheapshark.com/api/1.0/games?ids=${chunk.join(',')}'),
          headers: {'Accept': 'application/json', 'User-Agent': 'RadarGamerApp/1.0'},
        ).timeout(const Duration(seconds: 12));

        if (res.statusCode == 200) {
          final Map<String, dynamic> batchResult = jsonDecode(res.body);
          allBatchData.addAll(batchResult);
        }
      } catch (_) {}
    }

    // Procesar cada juego con los datos obtenidos en la llamada por lote
    for (int i = 0; i < updatedList.length; i++) {
      final g = updatedList[i];
      final gameId = g['gameID']?.toString();
      if (gameId == null || !allBatchData.containsKey(gameId)) continue;

      try {
        final gameData = allBatchData[gameId];
        final deals = (gameData['deals'] as List? ?? []).cast<Map<String, dynamic>>();
        final info = gameData['info'] as Map<String, dynamic>? ?? {};
        final steamAppID = info['steamAppID']?.toString();

        if (deals.isNotEmpty) {
          // Ordenar las ofertas para tomar el precio más bajo
          deals.sort((a, b) {
            final pA = double.tryParse(a['price'].toString()) ?? double.infinity;
            final pB = double.tryParse(b['price'].toString()) ?? double.infinity;
            return pA.compareTo(pB);
          });

          var best = deals.first;
          double currentBestPrice = double.tryParse(best['price'].toString()) ?? 0.0;

          // Si tiene Steam ID, verificar si el precio regional de Steam es menor
          if (steamAppID != null && steamAppID.isNotEmpty && steamAppID != 'null') {
            final steamData = await _fetchSteamDetails(steamAppID);
            if (steamData != null && steamData['price'] > 0 && steamData['price'] < currentBestPrice) {
              currentBestPrice = steamData['price'];
            }
          }

          final prevPrice = double.tryParse(g['salePrice'].toString()) ?? 0.0;
          if (currentBestPrice < prevPrice && prevPrice > 0) {
            droppedGameTitle = info['title'] ?? g['title'];
            droppedPrice = currentBestPrice;
          }

          List<dynamic> history = List.from(g['priceHistory'] ?? []);
          if (history.isEmpty || currentBestPrice != prevPrice) {
            history.add({
              'price': currentBestPrice,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            });
            anyChanged = true;
          }

          // Mantener o actualizar el mínimo histórico
          final oldHistLow = double.tryParse(g['historicalLow']?.toString() ?? '0.0') ?? 0.0;
          final newHistLow = (oldHistLow <= 0 || (currentBestPrice > 0 && currentBestPrice < oldHistLow))
              ? currentBestPrice
              : oldHistLow;

          updatedList[i] = {
            'gameID': gameId,
            'title': info['title'] ?? g['title'],
            'thumb': info['thumb'] ?? g['thumb'],
            'salePrice': currentBestPrice.toStringAsFixed(2),
            'normalPrice': best['retailPrice'] ?? g['normalPrice'],
            'storeID': best['storeID'] ?? g['storeID'],
            'dealID': best['dealID'] ?? g['dealID'],
            'steamAppID': steamAppID,
            'historicalLow': newHistLow,
            'historicalDate': g['historicalDate'] ?? 0,
            'priceHistory': history,
            'addedTimestamp': g['addedTimestamp'] ?? DateTime.now().millisecondsSinceEpoch,
          };
        }
      } catch (_) {}
    }

    if (mounted) {
      setState(() => _followedGames = updatedList);
      if (anyChanged) await _saveFollowed();
    }
    _isRefreshingFollowed = false;

    if (droppedGameTitle != null && mounted) {
      _triggerNotificationWithSound(
        '🔥 ¡Oferta en $droppedGameTitle!',
        'El juego bajó a \$$droppedPrice en tienda oficial.',
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
      _fetchFreebies(),
    ]);
    if (mounted) {
      await _refreshFollowed();
    }
  }

  Map<String, double> _calculateFollowedMinMax(List<dynamic>? history, double fallbackPrice) {
    if (history == null || history.isEmpty) {
      return {'min': fallbackPrice, 'max': fallbackPrice};
    }
    double minP = double.infinity;
    double maxP = double.negativeInfinity;
    for (var entry in history) {
      final p = double.tryParse(entry['price'].toString()) ?? 0.0;
      if (p > 0) {
        if (p < minP) minP = p;
        if (p > maxP) maxP = p;
      }
    }
    if (minP == double.infinity) minP = fallbackPrice;
    if (maxP == double.negativeInfinity) maxP = fallbackPrice;
    return {'min': minP, 'max': maxP};
  }

  List<Map<String, dynamic>> _getSortedFollowedGames() {
    List<Map<String, dynamic>> list = List.from(_followedGames);
    switch (_followedSortOption) {
      case 'price_asc':
        list.sort((a, b) {
          final pA = double.tryParse(a['salePrice'].toString()) ?? 0.0;
          final pB = double.tryParse(b['salePrice'].toString()) ?? 0.0;
          return pA.compareTo(pB);
        });
        break;
      case 'price_desc':
        list.sort((a, b) {
          final pA = double.tryParse(a['salePrice'].toString()) ?? 0.0;
          final pB = double.tryParse(b['salePrice'].toString()) ?? 0.0;
          return pB.compareTo(pA);
        });
        break;
      case 'title':
        list.sort((a, b) {
          final tA = (a['title'] ?? '').toString().toLowerCase();
          final tB = (b['title'] ?? '').toString().toLowerCase();
          return tA.compareTo(tB);
        });
        break;
      case 'recent':
        list.sort((a, b) {
          final tA = a['addedTimestamp'] ?? 0;
          final tB = b['addedTimestamp'] ?? 0;
          return (tB as num).compareTo(tA as num);
        });
        break;
    }
    return list;
  }

  void _showGameAllDealsModal(String gameID, String title, String thumb, {List<dynamic>? priceHistory}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141B26),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return FutureBuilder<http.Response>(
          future: http.get(
            Uri.parse('https://www.cheapshark.com/api/1.0/games?id=$gameID'),
            headers: {'Accept': 'application/json', 'User-Agent': 'RadarGamerApp/1.0'},
          ).timeout(const Duration(seconds: 8)),
          builder: (context, snapshot) {
            if (!snapshot.hasData && !snapshot.hasError) {
              return const SizedBox(
                height: 280,
                child: Center(child: CircularProgressIndicator(color: Color(0xFF00D2FF))),
              );
            }

            if (snapshot.hasError || (snapshot.hasData && snapshot.data!.statusCode != 200)) {
              final is429 = snapshot.hasData && snapshot.data!.statusCode == 429;
              return SizedBox(
                height: 280,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(is429 ? Icons.timer_outlined : Icons.cloud_off, color: const Color(0xFFFF5252), size: 36),
                        const SizedBox(height: 12),
                        Text(
                          is429
                              ? 'El servidor de ofertas está temporalmente ocupado.\nPor favor espera unos segundos y vuelve a abrir.'
                              : 'No se pudieron cargar las ofertas de este juego.\nVerifica tu conexión.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            final data = jsonDecode(snapshot.data!.body);
            final rawDeals = (data['deals'] as List? ?? []).cast<Map<String, dynamic>>();
            final cheapestEver = data['cheapestPriceEver'] as Map<String, dynamic>?;
            final steamAppID = data['info']?['steamAppID']?.toString();

            final lowestPrice = cheapestEver?['price'] != null
                ? double.tryParse(cheapestEver!['price'].toString()) ?? 0.0
                : 0.0;
            final lowestDateRaw = cheapestEver?['date'] ?? 0;
            final lowestDateStr = lowestDateRaw > 0
                ? DateFormat('dd/MM/yyyy').format(DateTime.fromMillisecondsSinceEpoch(lowestDateRaw * 1000))
                : 'N/A';

            return FutureBuilder<Map<String, dynamic>?>(
              future: (steamAppID != null && steamAppID.isNotEmpty && steamAppID != 'null')
                  ? _fetchSteamDetails(steamAppID)
                  : Future.value(null),
              builder: (context, steamSnapshot) {
                List<Map<String, dynamic>> consolidatedDeals = [];
                final steamData = steamSnapshot.data;
                final bool hasSteamInRaw = rawDeals.any((d) => d['storeID'] == '1');

                for (var d in rawDeals) {
                  if (d['storeID'] == '1' && steamData != null && steamData['price'] > 0) {
                    consolidatedDeals.add({
                      ...d,
                      'price': steamData['price'].toString(),
                      'retailPrice': steamData['regular'] > 0 ? steamData['regular'].toString() : d['retailPrice'],
                      'savings': steamData['discount'].toString(),
                      'isRegional': true,
                    });
                  } else {
                    consolidatedDeals.add(d);
                  }
                }

                if (!hasSteamInRaw && steamData != null && steamData['price'] > 0) {
                  consolidatedDeals.add({
                    'storeID': '1',
                    'price': steamData['price'].toString(),
                    'retailPrice': steamData['regular'] > 0 ? steamData['regular'].toString() : steamData['price'].toString(),
                    'savings': steamData['discount'].toString(),
                    'dealID': '',
                    'isRegional': true,
                  });
                }

                consolidatedDeals.sort((a, b) {
                  final pA = double.tryParse(a['price'].toString()) ?? 0.0;
                  final pB = double.tryParse(b['price'].toString()) ?? 0.0;
                  return pA.compareTo(pB);
                });

                final dlcIds = steamData != null ? (steamData['dlc_ids'] as List<int>?) ?? [] : <int>[];

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.85,
                    ),
                    child: SingleChildScrollView(
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

                          if (priceHistory != null && priceHistory.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Theme(
                              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0B0F17),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF1F293D)),
                                ),
                                child: ExpansionTile(
                                  initiallyExpanded: false,
                                  tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                                  leading: const Icon(Icons.history_toggle_off, color: Color(0xFF00F5A0), size: 20),
                                  title: const Text(
                                    'Historial de seguimiento',
                                    style: TextStyle(
                                      color: Color(0xFF00F5A0),
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${priceHistory.length} registros (toca para desplegar)',
                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                                  ),
                                  iconColor: const Color(0xFF00F5A0),
                                  collapsedIconColor: Colors.white54,
                                  childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                                  children: [
                                    const Divider(color: Color(0xFF1F293D), height: 1),
                                    const SizedBox(height: 8),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxHeight: 180),
                                      child: ListView(
                                        shrinkWrap: true,
                                        padding: EdgeInsets.zero,
                                        children: priceHistory.reversed.take(20).map((item) {
                                          final p = double.tryParse(item['price'].toString()) ?? 0.0;
                                          final ts = item['timestamp'] as int? ?? 0;
                                          final dateStr = ts > 0
                                              ? DateFormat('dd/MM/yyyy hh:mm a').format(DateTime.fromMillisecondsSinceEpoch(ts))
                                              : 'Inicial';
                                          final pVes = p * _vesRate;

                                          return Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 4),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Text(
                                                  dateStr,
                                                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                                                ),
                                                Row(
                                                  children: [
                                                    Text(
                                                      '\$${p.toStringAsFixed(2)}',
                                                      style: const TextStyle(
                                                        color: Color(0xFF00D2FF),
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                      '(Bs. ${_currencyFormat.format(pVes)})',
                                                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],

                          if (steamAppID != null && steamAppID.isNotEmpty && steamAppID != 'null' && dlcIds.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Text(
                              'Expansiones / DLCs (${dlcIds.length} disponibles):',
                              style: const TextStyle(color: Color(0xFF66C0F4), fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            FutureBuilder<List<Map<String, dynamic>>>(
                              future: _fetchSteamDlcs(dlcIds),
                              builder: (ctx, dlcSnap) {
                                if (!dlcSnap.hasData) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF66C0F4)),
                                      ),
                                    ),
                                  );
                                }
                                final dlcList = dlcSnap.data!;
                                if (dlcList.isEmpty) {
                                  return const Text(
                                    'Consultar complementos directamente en Steam',
                                    style: TextStyle(color: Colors.white38, fontSize: 11),
                                  );
                                }

                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0B0F17),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF1F293D)),
                                  ),
                                  child: Column(
                                    children: dlcList.map((d) {
                                      final dPrice = d['price'] as double;
                                      final dVes = dPrice * _vesRate;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 4),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.extension, color: Color(0xFF66C0F4), size: 14),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                d['name'],
                                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Text(
                                              '\$${dPrice.toStringAsFixed(2)}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF00F5A0),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '(Bs. ${_currencyFormat.format(dVes)})',
                                              style: const TextStyle(fontSize: 10, color: Colors.white38),
                                            ),
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                              icon: const Icon(Icons.open_in_new, color: Color(0xFF00D2FF), size: 14),
                                              onPressed: () {
                                                launchUrl(
                                                  Uri.parse('https://store.steampowered.com/app/${d['id']}'),
                                                  mode: LaunchMode.externalApplication,
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                );
                              },
                            ),
                          ],

                          const SizedBox(height: 14),
                          const Text(
                            'Precios por tienda (Ordenados por menor precio):',
                            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: consolidatedDeals.length,
                            separatorBuilder: (_, __) => const Divider(color: Color(0xFF1F293D)),
                            itemBuilder: (_, idx) {
                              final d = consolidatedDeals[idx];
                              final isSteamRegional = d['isRegional'] == true;
                              final storeName = isSteamRegional
                                  ? 'Steam (Precio Regional $_region)'
                                  : (_storesMap[d['storeID'].toString()] ?? 'Tienda #${d['storeID']}');
                              final price = double.tryParse(d['price'].toString()) ?? 0.0;
                              final priceVes = price * _vesRate;
                              final retail = double.tryParse(d['retailPrice'].toString()) ?? 0.0;
                              final savings = double.tryParse(d['savings'].toString()) ?? 0.0;

                              return ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: isSteamRegional
                                    ? Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1B2838),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Icon(Icons.sports_esports, color: Color(0xFF66C0F4), size: 18),
                                      )
                                    : null,
                                title: Text(
                                  storeName,
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                                ),
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
                                        final dealUrl = (d['dealID'] != null && d['dealID'].toString().isNotEmpty)
                                            ? 'https://www.cheapshark.com/redirect?dealID=${d['dealID']}'
                                            : 'https://store.steampowered.com/app/$steamAppID';
                                        launchUrl(Uri.parse(dealUrl), mode: LaunchMode.externalApplication);
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 14),
                        ],
                      ),
                    ),
                  ),
                );
              },
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
        followedGameIDs: _followedGames.map((g) => g['gameID'].toString()).toSet(),
        onToggleFollow: (game) {
          final gameId = game['gameID'].toString();
          if (game['remove'] == true) {
            setState(() {
              _followedGames.removeWhere((g) => g['gameID'].toString() == gameId);
            });
            _saveFollowed();
          } else {
            final exists = _followedGames.any((g) => g['gameID'].toString() == gameId);
            if (!exists) {
              final double initialPrice = double.tryParse(game['salePrice'].toString()) ?? 0.0;
              final now = DateTime.now().millisecondsSinceEpoch;
              final gameWithHistory = {
                ...game,
                'addedTimestamp': now,
                'priceHistory': [
                  {
                    'price': initialPrice,
                    'timestamp': now,
                  }
                ],
              };
              setState(() => _followedGames.add(gameWithHistory));
              _saveFollowed();
            }
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sortedFollowed = _getSortedFollowedGames();

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
                Text(
                  _isRateFromCache ? 'Binance P2P (Caché):' : 'Binance P2P:',
                  style: const TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w500),
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
                                '🇻🇪 LATAM-USD (cc=ve)',
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
                                '🇺🇸 USA Global (cc=us)',
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
              Tab(
                icon: const Icon(Icons.card_giftcard, size: 20),
                text: 'Gratis (${_freebies.length})',
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
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Ordenar por:',
                                    style: TextStyle(color: Colors.white54, fontSize: 12),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF141B26),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFF1F293D)),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _followedSortOption,
                                        isDense: true,
                                        dropdownColor: const Color(0xFF141B26),
                                        style: const TextStyle(color: Color(0xFF00D2FF), fontSize: 12, fontWeight: FontWeight.bold),
                                        icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF00D2FF), size: 18),
                                        items: const [
                                          DropdownMenuItem(
                                            value: 'price_asc',
                                            child: Text('Menor precio primero'),
                                          ),
                                          DropdownMenuItem(
                                            value: 'price_desc',
                                            child: Text('Mayor precio primero'),
                                          ),
                                          DropdownMenuItem(
                                            value: 'title',
                                            child: Text('Título (A-Z)'),
                                          ),
                                          DropdownMenuItem(
                                            value: 'recent',
                                            child: Text('Recientes'),
                                          ),
                                        ],
                                        onChanged: (val) {
                                          if (val != null) _saveSortOption(val);
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView.builder(
                                padding: const EdgeInsets.only(top: 4, bottom: 80, left: 12, right: 12),
                                itemCount: sortedFollowed.length,
                                itemBuilder: (ctx, i) {
                                  final game = sortedFollowed[i];
                                  final saleP = double.tryParse(game['salePrice'].toString()) ?? 0.0;
                                  final minMax = _calculateFollowedMinMax(game['priceHistory'] as List?, saleP);

                                  return _buildGameCard(
                                    title: game['title'] ?? '',
                                    thumb: game['thumb'] ?? '',
                                    salePrice: saleP,
                                    normalPrice: double.tryParse(game['normalPrice'].toString()) ?? 0.0,
                                    storeID: game['storeID']?.toString() ?? '1',
                                    dealID: game['dealID']?.toString() ?? '',
                                    gameID: game['gameID']?.toString() ?? '',
                                    historicalLow: double.tryParse(game['historicalLow']?.toString() ?? '0.0') ?? 0.0,
                                    isFollowed: true,
                                    followedMin: minMax['min'],
                                    followedMax: minMax['max'],
                                    priceHistory: game['priceHistory'] as List?,
                                    onDelete: () {
                                      setState(() {
                                        _followedGames.removeWhere((g) => g['gameID'] == game['gameID']);
                                      });
                                      _saveFollowed();
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
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
                RefreshIndicator(
                  color: const Color(0xFF00D2FF),
                  backgroundColor: const Color(0xFF141B26),
                  onRefresh: _handleRefreshAll,
                  child: _isLoadingFreebies
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D2FF)))
                      : _freebies.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 120),
                                Center(
                                  child: Text(
                                    'No hay juegos gratis reportados en este momento',
                                    style: TextStyle(color: Colors.white54),
                                  ),
                                )
                              ],
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(top: 8, bottom: 80, left: 12, right: 12),
                              itemCount: _freebies.length,
                              itemBuilder: (ctx, i) {
                                final f = _freebies[i];
                                final originalPrice = f['worth'] ?? 'N/A';
                                final platform = f['platforms'] ?? 'PC';
                                final giveawayUrl = f['open_giveaway_url'] ?? '';

                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 6),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.all(12),
                                    leading: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.network(
                                        f['image'] ?? '',
                                        width: 70,
                                        height: 42,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const Icon(Icons.card_giftcard),
                                      ),
                                    ),
                                    title: Text(
                                      f['title'] ?? '',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 4),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF00D2FF).withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            platform,
                                            style: const TextStyle(
                                              color: Color(0xFF00D2FF),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Antes: $originalPrice',
                                          style: const TextStyle(
                                            color: Colors.white38,
                                            fontSize: 11,
                                            decoration: TextDecoration.lineThrough,
                                          ),
                                        ),
                                      ],
                                    ),
                                    trailing: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF00F5A0),
                                        foregroundColor: Colors.black,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      ),
                                      onPressed: () {
                                        if (giveawayUrl.isNotEmpty) {
                                          launchUrl(Uri.parse(giveawayUrl), mode: LaunchMode.externalApplication);
                                        }
                                      },
                                      child: const Text('Reclamar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                    ),
                                  ),
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
    double? followedMin,
    double? followedMax,
    List<dynamic>? priceHistory,
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
            _showGameAllDealsModal(gameID, title, thumb, priceHistory: priceHistory);
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
                    if (isFollowed) ...[
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (followedMin != null)
                            Text(
                              'Min: \$${followedMin.toStringAsFixed(2)}',
                              style: const TextStyle(color: Color(0xFF00F5A0), fontSize: 10, fontWeight: FontWeight.w500),
                            ),
                          if (followedMax != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              'Max: \$${followedMax.toStringAsFixed(2)}',
                              style: const TextStyle(color: Color(0xFFFF5252), fontSize: 10, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ],
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
  final Set<String> followedGameIDs;
  final Function(Map<String, dynamic>) onToggleFollow;

  const SearchGameModal({
    super.key,
    required this.storesMap,
    required this.vesRate,
    required this.followedGameIDs,
    required this.onToggleFollow,
  });

  @override
  State<SearchGameModal> createState() => _SearchGameModalState();
}

class _SearchGameModalState extends State<SearchGameModal> {
  static final Map<String, List<Map<String, dynamic>>> _searchCache = {};

  final TextEditingController _controller = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  bool _hasSearched = false;
  String? _errorMessage;
  String _lastQuery = '';
  Timer? _debounceTimer;
  late Set<String> _localFollowedIDs;
  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'es_VE');

  @override
  void initState() {
    super.initState();
    _localFollowedIDs = Set<String>.from(widget.followedGameIDs);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  String _normalizeQuery(String q) {
    var s = q.trim();
    return s
        .replaceAll(RegExp(r'[áàäâã]'), 'a')
        .replaceAll(RegExp(r'[éèëê]'), 'e')
        .replaceAll(RegExp(r'[íìïî]'), 'i')
        .replaceAll(RegExp(r'[óòöôõ]'), 'o')
        .replaceAll(RegExp(r'[úùüû]'), 'u')
        .replaceAll(RegExp(r'[ñ]'), 'n')
        .replaceAll(RegExp(r'[ÁÀÄÂÃ]'), 'A')
        .replaceAll(RegExp(r'[ÉÈËÊ]'), 'E')
        .replaceAll(RegExp(r'[ÍÌÏÎ]'), 'I')
        .replaceAll(RegExp(r'[ÓÒÖÔÕ]'), 'O')
        .replaceAll(RegExp(r'[ÚÙÜÛ]'), 'U')
        .replaceAll(RegExp(r'[Ñ]'), 'N');
  }

  Future<void> _search(String query) async {
    _debounceTimer?.cancel();
    final cleanQuery = _normalizeQuery(query);
    if (cleanQuery.isEmpty) return;

    // 1. Respuesta instantánea (0 ms) si ya se buscó en esta sesión
    if (_searchCache.containsKey(cleanQuery)) {
      setState(() {
        _results = _searchCache[cleanQuery]!;
        _searching = false;
        _hasSearched = true;
        _errorMessage = null;
        _lastQuery = query.trim();
      });
      return;
    }

    setState(() {
      _searching = true;
      _errorMessage = null;
      _lastQuery = query.trim();
    });

    try {
      final res = await http.get(
        Uri.parse('https://www.cheapshark.com/api/1.0/games?title=${Uri.encodeComponent(cleanQuery)}&limit=25'),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'RadarGamerApp/1.0',
        },
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final List list = jsonDecode(res.body);
        final casted = list.cast<Map<String, dynamic>>();
        _searchCache[cleanQuery] = casted;
        if (mounted) {
          setState(() {
            _results = casted;
            _searching = false;
            _hasSearched = true;
          });
        }
        return;
      } else if (res.statusCode == 429) {
        if (mounted) {
          setState(() {
            _errorMessage = 'El servidor de ofertas está recibiendo muchas consultas en este momento. Espera unos segundos y vuelve a intentar.';
            _searching = false;
            _hasSearched = true;
          });
        }
        return;
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = 'El servidor de ofertas respondió con código ${res.statusCode}.';
            _searching = false;
            _hasSearched = true;
          });
        }
        return;
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _errorMessage = 'El servidor tardó demasiado en responder. Revisa tu conexión o reintenta.';
          _searching = false;
          _hasSearched = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMessage = 'No se pudo conectar con el servidor de ofertas. Revisa tu conexión.';
          _searching = false;
          _hasSearched = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D2FF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Buscar Juegos',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white60, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Buscar juego (ej. Resident Evil, Doom)...',
              prefixIcon: const Icon(Icons.search, color: Color(0xFF00D2FF)),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_controller.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear, color: Colors.white38, size: 18),
                      onPressed: () {
                        _controller.clear();
                        setState(() {
                          _results = [];
                          _hasSearched = false;
                          _errorMessage = null;
                        });
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward, color: Color(0xFF00D2FF)),
                    onPressed: () => _search(_controller.text),
                  ),
                ],
              ),
              filled: true,
              fillColor: const Color(0xFF0B0F17),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF1F293D)),
              ),
            ),
            onChanged: (val) {
              setState(() {});
              _debounceTimer?.cancel();
              if (val.trim().length >= 3) {
                _debounceTimer = Timer(const Duration(milliseconds: 750), () {
                  _search(val);
                });
              }
            },
            onSubmitted: _search,
          ),
          const SizedBox(height: 12),
          if (_searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00D2FF)),
                  SizedBox(height: 12),
                  Text(
                    'Consultando ofertas en tiendas oficiales...',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            )
          else if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, color: Color(0xFFFF5252), size: 36),
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1F293D),
                      foregroundColor: const Color(0xFF00D2FF),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reintentar', style: TextStyle(fontSize: 12)),
                    onPressed: () => _search(_controller.text),
                  ),
                ],
              ),
            )
          else if (_hasSearched && _results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.search_off, color: Colors.white38, size: 38),
                  const SizedBox(height: 8),
                  Text(
                    'No se encontraron resultados para "$_lastQuery"',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Consejo: Intenta con el título en inglés o una palabra clave más corta (ej. "Witcher" o "Batman").',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            )
          else if (!_hasSearched && _results.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sports_esports_outlined, color: Colors.white24, size: 36),
                  SizedBox(height: 8),
                  Text(
                    'Escribe el nombre de un juego para buscar ofertas.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.55,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _results.length,
                separatorBuilder: (_, __) => const Divider(color: Color(0xFF1F293D)),
                itemBuilder: (ctx, i) {
                  final g = _results[i];
                  final gameId = g['gameID']?.toString() ?? '';
                  final price = double.tryParse(g['cheapest'].toString()) ?? 0.0;
                  final priceVes = price * widget.vesRate;
                  final isFollowed = _localFollowedIDs.contains(gameId);

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
                    title: Text(
                      g['external'] ?? '',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'Mejor precio: \$$price (Bs. ${_currencyFormat.format(priceVes)})',
                      style: const TextStyle(color: Color(0xFF00F5A0), fontSize: 11),
                    ),
                    trailing: isFollowed
                        ? OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF00F5A0),
                              side: const BorderSide(color: Color(0xFF00F5A0)),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.check, size: 14, color: Color(0xFF00F5A0)),
                            label: const Text(
                              'Siguiendo',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              setState(() => _localFollowedIDs.remove(gameId));
                              widget.onToggleFollow({
                                'gameID': gameId,
                                'remove': true,
                              });
                            },
                          )
                        : ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00D2FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.add, size: 14, color: Colors.black),
                            label: const Text(
                              'Seguir',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              setState(() => _localFollowedIDs.add(gameId));
                              widget.onToggleFollow({
                                'gameID': gameId,
                                'title': g['external'] ?? '',
                                'thumb': g['thumb'] ?? '',
                                'salePrice': g['cheapest'] ?? '0.0',
                                'normalPrice': g['cheapest'] ?? '0.0',
                                'storeID': '1',
                                'dealID': g['cheapestDealID'] ?? '',
                                'historicalLow': g['cheapest'] ?? '0.0',
                              });
                            },
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
