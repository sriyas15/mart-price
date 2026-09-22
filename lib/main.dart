import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'link_accounts_screen.dart';
import 'cart_sync_service.dart';

void main() {
  runApp(const MartCompareApp());
}

class MartCompareApp extends StatelessWidget {
  const MartCompareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MartCompare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Data Models
// ---------------------------------------------------------------------------
class Product {
  final String platform;
  final String id;
  final String name;
  final String weight;
  final double price;
  final String imageUrl;
  final String eta;
  final String deepLink;
  final bool inStock;

  Product({
    required this.platform,
    required this.id,
    required this.name,
    required this.weight,
    required this.price,
    required this.imageUrl,
    required this.eta,
    required this.deepLink,
    this.inStock = true,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      platform: json['platform'] ?? '',
      id: json['id']?.toString() ?? '',
      name: json['product_name'] ?? json['name'] ?? 'Unknown',
      weight: json['weight'] ?? 'Standard',
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      imageUrl: json['image_url'] ?? '',
      eta: json['eta'] ?? '',
      deepLink: json['deep_link'] ?? '',
      inStock: json['in_stock'] ?? true,
    );
  }

  // For cart deduplication
  String get uniqueKey => '${platform}_${name}_$price';
}

class CartItem {
  final Product product;
  int quantity;

  CartItem({required this.product, this.quantity = 1});
}

// ---------------------------------------------------------------------------
// Platform visual config
// ---------------------------------------------------------------------------
class PlatformStyle {
  final Color color;
  final Color bgColor;
  final String logoUrl;

  const PlatformStyle(this.color, this.bgColor, this.logoUrl);
}

final Map<String, PlatformStyle> platformStyles = {
  'Blinkit': const PlatformStyle(
    Color(0xFFF5C518),
    Color(0xFFFFF9E0),
    'https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://blinkit.com&size=64',
  ),
  'Zepto': const PlatformStyle(
    Color(0xFF7B2FF2),
    Color(0xFFF3EAFF),
    'https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://zeptonow.com&size=64',
  ),
  'BigBasket': const PlatformStyle(
    Color(0xFF84C225),
    Color(0xFFF0F9E0),
    'https://t3.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://bigbasket.com&size=64',
  ),
};

// ---------------------------------------------------------------------------
// Chennai Areas
// ---------------------------------------------------------------------------
class ChennaiArea {
  final String name;
  final double lat;
  final double lon;
  const ChennaiArea(this.name, this.lat, this.lon);
}

const List<ChennaiArea> chennaiAreas = [
  ChennaiArea('T. Nagar', 13.0418, 80.2341),
  ChennaiArea('Anna Nagar', 13.0850, 80.2101),
  ChennaiArea('Velachery', 12.9815, 80.2180),
  ChennaiArea('Adyar', 13.0012, 80.2565),
  ChennaiArea('OMR (Thoraipakkam)', 12.9364, 80.2336),
  ChennaiArea('Porur', 13.0382, 80.1566),
  ChennaiArea('Tambaram', 12.9249, 80.1000),
  ChennaiArea('Mylapore', 13.0368, 80.2676),
];

// ---------------------------------------------------------------------------
// Home Screen
// ---------------------------------------------------------------------------
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Backend URL: Use 10.0.2.2 for Android emulator (maps to host localhost)
  static const String _backendBase = 'http://10.0.2.2:4000/api';

  // Location state
  double _lat = 13.0418;
  double _lon = 80.2341;
  String _locationLabel = 'T. Nagar';
  bool _gpsActive = false;

  // Address state (from reverse geocoding)
  String _street = '';
  String _subLocality = '';   // neighborhood (e.g., "T. Nagar")
  String _locality = '';      // city (e.g., "Chennai")
  String _postalCode = '';    // pincode (e.g., "600017")
  String _fullAddress = '';   // complete formatted address

  // Search state
  final TextEditingController _searchCtrl = TextEditingController();
  List<String> _suggestions = [];
  Timer? _debounce;

  // Results state: platform name -> list of products
  Map<String, List<Product>> _results = {};
  bool _isLoading = false;
  String? _errorMessage;

  // Cart state: platform name -> list of cart items
  final Map<String, List<CartItem>> _cart = {};

  int get _cartItemCount {
    int count = 0;
    for (final items in _cart.values) {
      for (final item in items) {
        count += item.quantity;
      }
    }
    return count;
  }

  @override
  void initState() {
    super.initState();
    _fetchSuggestions('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Location: GPS Auto-Detect
  // ---------------------------------------------------------------------------
  Future<void> _detectGpsLocation() async {
    setState(() => _errorMessage = null);
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showError('Location services are disabled. Please enable GPS.');
        return;
      }
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showError('Location permission denied.');
          return;
        }
      }
      if (permission == LocationPermission.deniedForever) {
        _showError('Location permission permanently denied. Use area dropdown.');
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      // Reverse geocode to get real address
      String addressLabel = 'GPS (${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)})';
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(
          position.latitude, position.longitude,
        );
        if (placemarks.isNotEmpty) {
          final place = placemarks.first;
          _street = place.street ?? '';
          _subLocality = place.subLocality ?? '';
          _locality = place.locality ?? '';
          _postalCode = place.postalCode ?? '';
          _fullAddress = [
            _street,
            _subLocality,
            _locality,
            _postalCode,
          ].where((s) => s.isNotEmpty).join(', ');
          addressLabel = _subLocality.isNotEmpty
              ? '$_subLocality, $_locality - $_postalCode'
              : _fullAddress;
        }
      } catch (e) {
        // Reverse geocoding failed, use raw coordinates as fallback
      }

      setState(() {
        _lat = position.latitude;
        _lon = position.longitude;
        _locationLabel = addressLabel;
        _gpsActive = true;
      });
      _showSuccess('Location detected: $_locationLabel');
    } catch (e) {
      _showError('GPS detection failed. Select an area manually.');
    }
  }

  void _selectArea(ChennaiArea area) {
    setState(() {
      _lat = area.lat;
      _lon = area.lon;
      _locationLabel = area.name;
      _gpsActive = false;
      _errorMessage = null;
    });
    _showSuccess('Location set to ${area.name}');
  }

  // ---------------------------------------------------------------------------
  // Search Suggestions
  // ---------------------------------------------------------------------------
  Future<void> _fetchSuggestions(String query) async {
    try {
      final uri =
          Uri.parse('$_backendBase/suggestions?q=${Uri.encodeComponent(query)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _suggestions = List<String>.from(data['suggestions'] ?? []);
        });
      }
    } catch (_) {}
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(text);
    });
  }

  // ---------------------------------------------------------------------------
  // Core: Run search comparison
  // ---------------------------------------------------------------------------
  Future<void> _runComparison(String query) async {
    if (query.trim().isEmpty) {
      _showError('Please enter a product name to search.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _results = {};
    });

    try {
      final uri = Uri.parse(
        '$_backendBase/compare?query=${Uri.encodeComponent(query)}&lat=$_lat&lon=$_lon&pincode=$_postalCode',
      );
      final response =
          await http.get(uri).timeout(const Duration(seconds: 60));
      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        final Map<String, dynamic> rawResults = data['results'] ?? {};
        final Map<String, List<Product>> parsed = {};
        rawResults.forEach((platform, products) {
          parsed[platform] = (products as List)
              .map((p) => Product.fromJson(p as Map<String, dynamic>))
              .toList();
        });
        setState(() => _results = parsed);
        final total =
            parsed.values.fold<int>(0, (s, list) => s + list.length);
        _showSuccess('Found $total products across ${parsed.length} platforms!');
      } else {
        _showError(data['message'] ?? 'Could not find "$query".');
      }
    } on TimeoutException {
      _showError('Request timed out. Please try again.');
    } catch (e) {
      _showError(
          'Cannot connect to backend. Make sure the server is running on port 4000.');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Cart Management
  // ---------------------------------------------------------------------------
  void _addToCart(Product product) {
    setState(() {
      _cart.putIfAbsent(product.platform, () => []);
      final items = _cart[product.platform]!;
      final index = items.indexWhere((p) => p.product.uniqueKey == product.uniqueKey);
      
      if (index == -1) {
        items.add(CartItem(product: product, quantity: 1));
        _showSuccess('${product.name} added to cart!');
      } else {
        items[index].quantity++;
      }
    });
  }

  void _updateCartQuantity(Product product, int delta) {
    setState(() {
      if (!_cart.containsKey(product.platform)) return;
      final items = _cart[product.platform]!;
      final index = items.indexWhere((p) => p.product.uniqueKey == product.uniqueKey);
      if (index != -1) {
        items[index].quantity += delta;
        if (items[index].quantity <= 0) {
          items.removeAt(index);
          if (items.isEmpty) {
            _cart.remove(product.platform);
          }
        }
      }
    });
  }

  void _removeFromCart(String platform, int index) {
    setState(() {
      _cart[platform]?.removeAt(index);
      if (_cart[platform]?.isEmpty ?? true) {
        _cart.remove(platform);
      }
    });
  }

  void _clearCart() {
    setState(() => _cart.clear());
    _showSuccess('Cart cleared.');
  }

  // ---------------------------------------------------------------------------
  // Deep Link: Open Mart App
  // ---------------------------------------------------------------------------
  Future<void> _openMartApp(String url, String platform) async {
    final uri = Uri.parse(url);
    try {
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        _showError('Could not open $platform. The app may not be installed.');
      }
    } catch (_) {
      _showError('Failed to launch $platform link.');
    }
  }

  // ---------------------------------------------------------------------------
  // Feedback Helpers
  // ---------------------------------------------------------------------------
  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showError(String message) {
    setState(() => _errorMessage = message);
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F9), // Light grey background
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              // Placeholder for future logo
            ),
            const SizedBox(width: 12),
            const Text(
              'MartCompare', // Kept app name but styled like PriceMint
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20, color: Color(0xFF4F46E5)),
            ),
          ],
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF4F46E5),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline, size: 28),
            tooltip: 'Profile / Link Accounts',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const LinkAccountsScreen()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildLocationBar(),
          _buildSearchBar(),
          Expanded(child: _buildContent()),
        ],
      ),
      floatingActionButton: _cartItemCount > 0
          ? FloatingActionButton.extended(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => CartScreen(
                      cart: _cart,
                      onRemove: _removeFromCart,
                      onClear: _clearCart,
                      onOpenApp: _openMartApp,
                      onUpdateQuantity: _updateCartQuantity,
                      lat: _lat,
                      lon: _lon,
                      postalCode: _postalCode,
                    ),
                  ),
                );
              },
              backgroundColor: const Color(0xFF4F46E5),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.shopping_cart),
              label: Text('View Cart ($_cartItemCount)'),
            )
          : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Location Bar
  // ---------------------------------------------------------------------------
  Widget _buildLocationBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.location_on,
            size: 18,
            color: Color(0xFF4F46E5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Location search coming soon!')),
                );
              },
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      _locationLabel == 'T. Nagar' ? 'Select location' : '$_locationLabel${_postalCode.isNotEmpty ? ', $_postalCode' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.black87),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: _detectGpsLocation,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF4F46E5),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Row(
              children: [
                Icon(Icons.gps_fixed, size: 14, color: _gpsActive ? const Color(0xFF28A745) : const Color(0xFF4F46E5)),
                const SizedBox(width: 4),
                const Text('Use GPS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ]
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Search Bar & Banner
  // ---------------------------------------------------------------------------
  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search Field
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(Icons.search, color: Colors.grey),
                ),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: _onSearchChanged,
                    onSubmitted: (val) {
                      _fetchSuggestions(''); // close suggestions
                      _runComparison(val);
                    },
                    decoration: const InputDecoration(
                      hintText: 'Search for products (e.g. milk, rice, apple)',
                      hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_searchCtrl.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    onPressed: () {
                      _searchCtrl.clear();
                      _fetchSuggestions('');
                    },
                  ),
              ],
            ),
          ),
          
          // Category Chips (Shown after searching)
          if (_results.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 12),
              height: 32,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: ['All', 'Milk', 'Paneer', 'Curd', 'Cheese'].map((category) {
                  final isSelected = category == 'All'; // For now, mock selection
                  return Container(
                    margin: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(category, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                      selected: isSelected,
                      onSelected: (bool selected) {
                        if (category != 'All') {
                          _searchCtrl.text = category;
                          _runComparison(category);
                        }
                      },
                      selectedColor: const Color(0xFF4F46E5),
                      labelStyle: TextStyle(color: isSelected ? Colors.white : Colors.black87),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: isSelected ? const Color(0xFF4F46E5) : Colors.grey.shade300),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            
          // Promotional Banner (Shown when no search results or before searching)
          if (_results.isEmpty && !_isLoading && _searchCtrl.text.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 16),
              height: 120, // fixed rectangular height
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF4F46E5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Compare Prices\nSave More Everyday',
                          style: TextStyle(color: Color(0xFFFFC107), fontSize: 16, fontWeight: FontWeight.bold, height: 1.2),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Find the best prices across Blinkit, Zepto and more.',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network('https://images.unsplash.com/photo-1542838132-92c53300491e?auto=format&fit=crop&q=80&w=150', width: 90, height: 90, fit: BoxFit.cover),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Content Area
  // ---------------------------------------------------------------------------
  Widget _buildContent() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF1A73E8)),
            const SizedBox(height: 14),
            Text(
              'Searching across platforms...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 4),
            Text(
              'This may take 10-15 seconds',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null && _results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline,
                    color: Colors.red.shade400, size: 40),
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.red.shade700, fontSize: 14),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _runComparison(
                    _searchCtrl.text.isEmpty
                        ? 'Amul Butter'
                        : _searchCtrl.text,
                  ),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Try Again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A73E8),
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shopping_cart_outlined,
                  size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                'Search for a product to compare\nprices across Blinkit, Zepto & BigBasket',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              Text(
                'Add items from any platform to your cart',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    // Show platform sections with horizontal scrolling products
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 80),
      children: _results.entries.map((entry) {
        return _buildPlatformSection(entry.key, entry.value);
      }).toList(),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Platform Section (header + horizontal product list)
  // ---------------------------------------------------------------------------
  Widget _buildPlatformSection(String platform, List<Product> products) {
    final style = platformStyles[platform] ??
        PlatformStyle(Colors.grey, Colors.grey.shade100, '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Platform header
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: style.bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: style.color.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  style.logoUrl,
                  height: 24,
                  width: 24,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Icon(Icons.store, color: style.color, size: 24),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                platform,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: style.color,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: style.color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${products.length} items',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: style.color,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Horizontal scrolling product cards
        SizedBox(
          height: 260, // Adjusted height to prevent bottom overflow
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            itemCount: products.length,
            itemBuilder: (context, index) {
              return _buildProductCard(products[index], style);
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Individual Product Card (inside horizontal scroll)
  // ---------------------------------------------------------------------------
  Widget _buildProductCard(Product product, PlatformStyle style) {
    final cartItems = _cart[product.platform] ?? [];
    final cartItemIndex = cartItems.indexWhere((p) => p.product.uniqueKey == product.uniqueKey);
    final isInCart = cartItemIndex != -1;
    final quantity = isInCart ? cartItems[cartItemIndex].quantity : 0;

    final isOutOfStock = !product.inStock || product.name.toLowerCase().contains('out of stock') ||
        product.weight.toLowerCase().contains('out of stock');

    return Opacity(
      opacity: isOutOfStock ? 0.5 : 1.0,
      child: Container(
        width: 160,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isInCart ? const Color(0xFF4F46E5) : Colors.grey.shade200,
            width: isInCart ? 1.5 : 1,
          ),
          boxShadow: [
            if (!isOutOfStock)
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Optional image
              if (product.imageUrl.isNotEmpty) ...[
                Center(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Image.network(
                        product.imageUrl,
                        height: 70,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox(height: 70),
                      ),
                      if (isOutOfStock)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'OUT OF STOCK',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              // Product name
              Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              // Weight
              Text(
                product.weight,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
              const Spacer(),
              // ETA and Price
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '₹${product.price.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(Icons.bolt, size: 14, color: Colors.green.shade600),
                      Text(
                        product.eta.replaceAll(' mins', 'm').replaceAll(' min', 'm'),
                        style: TextStyle(fontSize: 11, color: Colors.green.shade700, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Add to cart button
              SizedBox(
                width: double.infinity,
                height: 36,
                child: isOutOfStock
                    ? ElevatedButton(
                        onPressed: null,
                        style: ElevatedButton.styleFrom(
                          disabledBackgroundColor: Colors.grey.shade200,
                          disabledForegroundColor: Colors.grey.shade500,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Out of Stock', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      )
                    : isInCart
                        ? Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                IconButton(
                                  icon: Icon(quantity == 1 ? Icons.delete_outline : Icons.remove, size: 18),
                                  color: quantity == 1 ? Colors.red.shade400 : const Color(0xFF4F46E5),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _updateCartQuantity(product, -1),
                                ),
                                Text(
                                  '$quantity',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF4F46E5),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.add, size: 18),
                                  color: const Color(0xFF4F46E5),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () => _updateCartQuantity(product, 1),
                                ),
                              ],
                            ),
                          )
                        : ElevatedButton(
                            onPressed: () => _addToCart(product),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4F46E5),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('Add to cart', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Cart Screen
// ===========================================================================
class CartScreen extends StatefulWidget {
  final Map<String, List<CartItem>> cart;
  final void Function(String platform, int index) onRemove;
  final VoidCallback onClear;
  final Future<void> Function(String url, String platform) onOpenApp;
  final void Function(Product product, int delta) onUpdateQuantity;
  final double lat;
  final double lon;
  final String postalCode;

  const CartScreen({
    super.key,
    required this.cart,
    required this.onRemove,
    required this.onClear,
    required this.onOpenApp,
    required this.onUpdateQuantity,
    required this.lat,
    required this.lon,
    required this.postalCode,
  });

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  static const platformChannel = MethodChannel('mart_price/accessibility');
  final _storage = const FlutterSecureStorage();
  bool _isSyncing = false;
  String? _syncingPlatform;

  // Helper: Inject location cookies into InAppWebView CookieManager
  Future<void> _injectLocationCookies(String platformName, double lat, double lon, String postalCode) async {
    final cookieManager = CookieManager.instance();
    
    if (platformName == 'Blinkit') {
      await cookieManager.setCookie(url: WebUri('https://blinkit.com'), name: 'gr_1_lat', value: lat.toString());
      await cookieManager.setCookie(url: WebUri('https://blinkit.com'), name: 'gr_1_lon', value: lon.toString());
      if (postalCode.isNotEmpty) {
        await cookieManager.setCookie(url: WebUri('https://blinkit.com'), name: 'gr_1_locality', value: postalCode);
      }
    } else if (platformName == 'Zepto') {
      // Zepto uses server-side session; set geolocation via WebView JS
      await cookieManager.setCookie(url: WebUri('https://www.zeptonow.com'), name: 'user_lat', value: lat.toString());
      await cookieManager.setCookie(url: WebUri('https://www.zeptonow.com'), name: 'user_lon', value: lon.toString());
    } else if (platformName == 'BigBasket') {
      await cookieManager.setCookie(url: WebUri('https://www.bigbasket.com'), name: 'bb_lat', value: lat.toString());
      await cookieManager.setCookie(url: WebUri('https://www.bigbasket.com'), name: 'bb_lng', value: lon.toString());
      await cookieManager.setCookie(url: WebUri('https://www.bigbasket.com'), name: '_bb_locSrc', value: 'session');
      if (postalCode.isNotEmpty) {
        await cookieManager.setCookie(url: WebUri('https://www.bigbasket.com'), name: 'pincode', value: postalCode);
      }
    }
  }
  
  Future<void> _triggerAutoCart(String platformName, List<CartItem> items) async {
    final linkedKey = platformName == 'BigBasket' ? 'bigbasket_linked' : 
                      platformName == 'Zepto' ? 'zepto_linked' : 'blinkit_linked';
    final checkoutUrl = platformName == 'BigBasket' ? 'https://www.bigbasket.com/basket/' :
                        platformName == 'Zepto' ? 'https://www.zeptonow.com/' : 'https://blinkit.com/';
                        
    final linkedStr = await _storage.read(key: linkedKey);
    
    if (linkedStr == 'true') {
      if (!mounted) return;
      setState(() {
        _isSyncing = true;
        _syncingPlatform = platformName;
      });
      
      try {
        final itemList = items.map((i) => {
          'id': i.product.id,
          'name': i.product.name,
          'price': i.product.price,
          'quantity': i.quantity
        }).toList();

        Map<String, dynamic> result;
        if (platformName == 'BigBasket') {
          result = await CartSyncService.syncBigBasket(itemList, widget.lat, widget.lon, widget.postalCode);
        } else if (platformName == 'Zepto') {
          result = await CartSyncService.syncZepto(itemList, widget.lat, widget.lon, widget.postalCode);
        } else {
          result = await CartSyncService.syncBlinkit(itemList, widget.lat, widget.lon, widget.postalCode);
        }

        if ((result['errors'] as List).isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Successfully synced ${result['added']} items to $platformName via WebView!")),
          );
          // Inject location cookies before opening checkout WebView (Method 5)
          await _injectLocationCookies(platformName, widget.lat, widget.lon, widget.postalCode);
          Navigator.push(context, MaterialPageRoute(builder: (context) => Scaffold(
            appBar: AppBar(title: Text('$platformName Checkout')),
            body: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(checkoutUrl)),
              initialSettings: InAppWebViewSettings(
                useShouldOverrideUrlLoading: true,
              ),
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                var uri = navigationAction.request.url!;
                if (!["http", "https", "file", "chrome", "data", "javascript", "about"].contains(uri.scheme)) {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
            ),
          )));
        } else {
          if (!mounted) return;
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Sync Errors'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: SelectableText(result['errors'].join('\n\n')),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context); // Close dialog
                    // Inject location cookies before checkout
                    await _injectLocationCookies(platformName, widget.lat, widget.lon, widget.postalCode);
                    // Open visible InAppWebView
                    Navigator.push(context, MaterialPageRoute(builder: (context) => Scaffold(
                      appBar: AppBar(title: Text('\$platformName Checkout')),
                      body: InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(checkoutUrl)),
                        initialSettings: InAppWebViewSettings(
                          useShouldOverrideUrlLoading: true,
                        ),
                        shouldOverrideUrlLoading: (controller, navigationAction) async {
                          var uri = navigationAction.request.url!;
                          if (!["http", "https", "file", "chrome", "data", "javascript", "about"].contains(uri.scheme)) {
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                      ),
                    )));
                  },
                  child: const Text('Continue to Checkout', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error during sync: \$e')),
        );
      } finally {
        if (mounted) setState(() {
          _isSyncing = false;
          _syncingPlatform = null;
        });
      }
    } else {
      // Not linked, prompt them
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Connect \$platformName Account'),
          content: Text('For instant background syncing, please link your \$platformName account.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _runAccessibilityFallback(platformName, items); // Fallback to old method
              },
              child: const Text('Use old method'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const LinkAccountsScreen()),
                );
              },
              child: const Text('Link Account'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _runAccessibilityFallback(String platformName, List<CartItem> items) async {
    final deepLink = items.isNotEmpty ? items.first.product.deepLink : '';
    await widget.onOpenApp(deepLink, platformName);
    
    // Also trigger accessibility method channel
    final itemList = items.map((i) => {
      'id': i.product.id,
      'name': i.product.name,
      'price': i.product.price,
      'quantity': i.quantity,
    }).toList();

    try {
      await platformChannel.invokeMethod('add_to_cart', {
        'platform': platformName,
        'items': itemList,
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isEmpty = widget.cart.isEmpty ||
        widget.cart.values.every((list) => list.isEmpty);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Your Cart',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.black87),
        elevation: 0,
        actions: [
          if (!isEmpty)
            TextButton(
              onPressed: () {
                widget.onClear();
                setState(() {});
              },
              child: const Text(
                'Clear All',
                style: TextStyle(color: Color(0xFF4F46E5), fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: isEmpty ? _buildEmptyCart() : _buildCartContent(),
    );
  }

  Widget _buildEmptyCart() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shopping_cart_outlined,
              size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'Your cart is empty',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Search for products and add them to your cart',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildCartContent() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: widget.cart.entries
          .where((e) => e.value.isNotEmpty)
          .map((entry) {
        return _buildPlatformCartGroup(entry.key, entry.value);
      }).toList(),
    );
  }

  Widget _buildPlatformCartGroup(
      String platform, List<CartItem> items) {
    final style = platformStyles[platform] ??
        PlatformStyle(Colors.grey, Colors.grey.shade100, '');

    final subtotal = items.fold<double>(0, (sum, p) => sum + (p.product.price * p.quantity));
    final deepLink = items.isNotEmpty ? items.first.product.deepLink : '';

    final itemList = items.map((i) => {
      'id': i.product.id,
      'name': i.product.name,
      'price': i.product.price,
      'quantity': i.quantity,
    }).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: style.color.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Platform header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: style.bgColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(
                    style.logoUrl,
                    height: 24,
                    width: 24,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Icon(Icons.store, color: style.color, size: 24),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  platform,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: style.color,
                  ),
                ),
                const Spacer(),
                Text(
                  '${items.length} item${items.length > 1 ? 's' : ''}',
                  style: TextStyle(
                    fontSize: 13,
                    color: style.color.withOpacity(0.7),
                  ),
                ),
              ],
            ),
          ),

          // Item list
          ...List.generate(items.length, (index) {
            final cartItem = items[index];
            final item = cartItem.product;
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: item.imageUrl.isNotEmpty
                  ? Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      padding: const EdgeInsets.all(4),
                      child: Image.network(
                        item.imageUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.image_not_supported, color: Colors.grey.shade400, size: 24),
                      ),
                    )
                  : Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.image, color: Colors.grey.shade400, size: 24),
                    ),
              title: Text(
                item.name,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
              ),
              subtitle: Text(
                item.weight,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '₹${(item.price * cartItem.quantity).toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: Icon(cartItem.quantity == 1 ? Icons.delete_outline : Icons.remove, size: 16),
                          color: cartItem.quantity == 1 ? Colors.red.shade400 : const Color(0xFF4F46E5),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          onPressed: () {
                            if (cartItem.quantity == 1) {
                              widget.onRemove(platform, index);
                            } else {
                              widget.onUpdateQuantity(item, -1);
                            }
                            setState(() {});
                          },
                        ),
                        Text(
                          '${cartItem.quantity}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF4F46E5)),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add, size: 16),
                          color: const Color(0xFF4F46E5),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          onPressed: () {
                            widget.onUpdateQuantity(item, 1);
                            setState(() {});
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),

          const Divider(height: 1),

          // Subtotal row
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Subtotal (base prices):',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                Text(
                  '₹${subtotal.toStringAsFixed(0)}',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: style.color,
                  ),
                ),
              ],
            ),
          ),

          // Disclaimer
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Colors.amber.shade800),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Excludes delivery, handling & tax charges. Final total may differ.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.amber.shade900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Open app & Auto-Cart buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      onPressed: () => widget.onOpenApp(deepLink, platform),
                      icon: const Icon(Icons.open_in_new, size: 18, color: Color(0xFF4F46E5)),
                      label: const Text(
                        'Open App',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF4F46E5)),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF4F46E5)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: _isSyncing ? null : () => _triggerAutoCart(platform, items),
                      icon: _isSyncing && _syncingPlatform == platform
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: Text(
                        _isSyncing && _syncingPlatform == platform ? 'Syncing...' : 'Auto-Fill Cart',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4F46E5),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
