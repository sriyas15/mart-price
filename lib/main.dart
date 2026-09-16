import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

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
  final String name;
  final String weight;
  final double price;
  final String imageUrl;
  final String eta;
  final String deepLink;

  Product({
    required this.platform,
    required this.name,
    required this.weight,
    required this.price,
    required this.imageUrl,
    required this.eta,
    required this.deepLink,
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      platform: json['platform'] ?? '',
      name: json['product_name'] ?? 'Unknown',
      weight: json['weight'] ?? 'Standard',
      price: (json['price'] as num).toDouble(),
      imageUrl: json['image_url'] ?? '',
      eta: json['eta'] ?? '',
      deepLink: json['deep_link'] ?? '',
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
  final IconData icon;

  const PlatformStyle(this.color, this.bgColor, this.icon);
}

final Map<String, PlatformStyle> platformStyles = {
  'Blinkit': PlatformStyle(
    const Color(0xFFF5C518),
    const Color(0xFFFFF9E0),
    Icons.flash_on,
  ),
  'Zepto': PlatformStyle(
    const Color(0xFF7B2FF2),
    const Color(0xFFF3EAFF),
    Icons.bolt,
  ),
  'BigBasket': PlatformStyle(
    const Color(0xFF84C225),
    const Color(0xFFF0F9E0),
    Icons.shopping_basket,
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
      setState(() {
        _lat = position.latitude;
        _lon = position.longitude;
        _locationLabel =
            'GPS (${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)})';
        _gpsActive = true;
      });
      _showSuccess('Location detected via GPS!');
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
        '$_backendBase/compare?query=${Uri.encodeComponent(query)}&lat=$_lat&lon=$_lon',
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
      appBar: AppBar(
        title: const Text(
          'MartCompare',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: const Color(0xFF1A73E8),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_gpsActive ? Icons.gps_fixed : Icons.gps_not_fixed),
            tooltip: 'Detect GPS location',
            onPressed: _detectGpsLocation,
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
                    ),
                  ),
                );
              },
              backgroundColor: const Color(0xFF1A73E8),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.shopping_cart),
              label: Text('Cart ($_cartItemCount)'),
            )
          : null,
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Location Bar
  // ---------------------------------------------------------------------------
  Widget _buildLocationBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A73E8).withOpacity(0.08),
      ),
      child: Row(
        children: [
          Icon(
            _gpsActive ? Icons.gps_fixed : Icons.location_on,
            size: 16,
            color: const Color(0xFF1A73E8),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _gpsActive
                    ? null
                    : chennaiAreas
                        .indexWhere((a) => a.name == _locationLabel),
                hint: Text(
                  _locationLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A73E8),
                  ),
                ),
                isExpanded: true,
                isDense: true,
                items: List.generate(chennaiAreas.length, (i) {
                  return DropdownMenuItem(
                    value: i,
                    child: Text(chennaiAreas[i].name),
                  );
                }),
                onChanged: (index) {
                  if (index != null) {
                    _selectArea(chennaiAreas[index]);
                  }
                },
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _detectGpsLocation,
            icon: const Icon(Icons.my_location, size: 14),
            label: const Text('Use GPS', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1A73E8),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Search Bar
  // ---------------------------------------------------------------------------
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  onSubmitted: _runComparison,
                  decoration: InputDecoration(
                    hintText: 'Search item (e.g. milk, butter, chips)',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _runComparison(_searchCtrl.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A73E8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      vertical: 14, horizontal: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Search'),
              ),
            ],
          ),
          if (_suggestions.isNotEmpty && !_isLoading) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _suggestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  return ActionChip(
                    label: Text(
                      _suggestions[index],
                      style: const TextStyle(fontSize: 12),
                    ),
                    backgroundColor: const Color(0xFFE8F0FE),
                    side: BorderSide(
                        color: const Color(0xFF1A73E8).withOpacity(0.3)),
                    onPressed: () {
                      _searchCtrl.text = _suggestions[index];
                      _runComparison(_suggestions[index]);
                    },
                  );
                },
              ),
            ),
          ],
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
        PlatformStyle(Colors.grey, Colors.grey.shade100, Icons.store);

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
              Icon(style.icon, color: style.color, size: 22),
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
          height: 320, // Increased height to completely resolve bottom overflow
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

    final isOutOfStock = product.name.toLowerCase().contains('out of stock') ||
        product.weight.toLowerCase().contains('out of stock');

    return Opacity(
      opacity: isOutOfStock ? 0.5 : 1.0,
      child: Container(
        width: 160,
        margin: const EdgeInsets.only(right: 10),
        decoration: BoxDecoration(
          color: isOutOfStock ? Colors.grey.shade100 : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isInCart ? style.color : Colors.grey.shade200,
            width: isInCart ? 2 : 1,
          ),
          boxShadow: [
            if (!isOutOfStock)
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
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
                child: Image.network(
                  product.imageUrl,
                  height: 60,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox(height: 60),
                ),
              ),
              const SizedBox(height: 8),
            ],
            // Product name
            Text(
              product.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            // Weight
            Text(
              product.weight,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
              ),
            ),
            const Spacer(),
            // Price
            Text(
              '₹${product.price.toStringAsFixed(0)}',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: style.color,
              ),
            ),
            const SizedBox(height: 4),
            // ETA
            Row(
              children: [
                Icon(Icons.access_time, size: 12, color: Colors.grey.shade500),
                const SizedBox(width: 3),
                Text(
                  product.eta,
                  style: TextStyle(
                      fontSize: 10, color: Colors.grey.shade500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Add to cart button
            SizedBox(
              width: double.infinity,
              height: 32,
              child: isOutOfStock
                  ? ElevatedButton(
                      onPressed: null,
                      style: ElevatedButton.styleFrom(
                        disabledBackgroundColor: Colors.grey.shade300,
                        disabledForegroundColor: Colors.grey.shade600,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('Out of Stock', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    )
                  : isInCart
                      ? Container(
                          decoration: BoxDecoration(
                            color: style.color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: style.color),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove, size: 16),
                                color: style.color,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _updateCartQuantity(product, -1),
                              ),
                              Text(
                                '$quantity',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: style.color,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add, size: 16),
                                color: style.color,
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
                            backgroundColor: style.color,
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.zero,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            elevation: 0,
                          ),
                          child: const Text('Add to Cart', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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

  const CartScreen({
    super.key,
    required this.cart,
    required this.onRemove,
    required this.onClear,
    required this.onOpenApp,
  });

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  @override
  Widget build(BuildContext context) {
    final isEmpty = widget.cart.isEmpty ||
        widget.cart.values.every((list) => list.isEmpty);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Your Cart',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF1A73E8),
        foregroundColor: Colors.white,
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
                style: TextStyle(color: Colors.white70, fontSize: 13),
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
        PlatformStyle(Colors.grey, Colors.grey.shade100, Icons.store);

    final subtotal = items.fold<double>(0, (sum, p) => sum + (p.product.price * p.quantity));
    final deepLink = items.isNotEmpty ? items.first.product.deepLink : '';

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
                Icon(style.icon, color: style.color, size: 22),
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
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              title: Text(
                item.name,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              subtitle: Text(
                '${item.weight}  •  Qty: ${cartItem.quantity}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '₹${(item.price * cartItem.quantity).toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: style.color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () {
                      widget.onRemove(platform, index);
                      setState(() {});
                    },
                    icon: Icon(Icons.close,
                        size: 18, color: Colors.red.shade400),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                        minWidth: 28, minHeight: 28),
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

          // Open app button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed: () => widget.onOpenApp(deepLink, platform),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: Text(
                  'Open $platform',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: style.color,
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
    );
  }
}
