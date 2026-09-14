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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Pre-mapped Chennai area coordinates for manual location selection
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
  // Use your machine's local network IP when testing on a physical device.
  // Use 10.0.2.2 for Android emulator (maps to host localhost).
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

  // Results state
  List<dynamic> _results = [];
  bool _isLoading = false;
  String? _errorMessage;

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
    setState(() {
      _errorMessage = null;
    });

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showError('Location services are disabled. Please enable GPS.');
        return;
      }

      // Check and request permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showError('Location permission denied. Please select an area manually.');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showError(
          'Location permission permanently denied. Use the area dropdown instead.',
        );
        return;
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      setState(() {
        _lat = position.latitude;
        _lon = position.longitude;
        _locationLabel = 'GPS (${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)})';
        _gpsActive = true;
      });

      _showSuccess('Location detected via GPS!');
    } catch (e) {
      _showError('GPS detection failed. Please select an area manually.');
    }
  }

  // ---------------------------------------------------------------------------
  // Location: Manual Area Selection
  // ---------------------------------------------------------------------------
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
  // Search: Fetch Auto-Suggestions from Backend
  // ---------------------------------------------------------------------------
  Future<void> _fetchSuggestions(String query) async {
    try {
      final uri = Uri.parse('$_backendBase/suggestions?q=${Uri.encodeComponent(query)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _suggestions = List<String>.from(data['suggestions'] ?? []);
        });
      }
    } catch (_) {
      // Suggestions are non-critical; fail silently
    }
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _fetchSuggestions(text);
    });
  }

  // ---------------------------------------------------------------------------
  // Core: Execute Landed Cost Comparison
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
      _results = [];
    });

    try {
      final uri = Uri.parse(
        '$_backendBase/compare?query=${Uri.encodeComponent(query)}&lat=$_lat&lon=$_lon',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = json.decode(response.body);

      if (response.statusCode == 200 && data['success'] == true) {
        setState(() {
          _results = data['results'] ?? [];
        });
        _showSuccess('Found ${_results.length} mart prices for $_locationLabel!');
      } else {
        _showError(data['message'] ?? 'Could not find "$query".');
      }
    } on TimeoutException {
      _showError('Request timed out. Please check your connection and try again.');
    } catch (e) {
      _showError('Cannot connect to backend. Make sure the Node.js server is running on port 4000.');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Deep Link: Open Mart App
  // ---------------------------------------------------------------------------
  Future<void> _openMartApp(String url, String platform) async {
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
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
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        actions: [
          // GPS auto-detect button
          IconButton(
            icon: Icon(_gpsActive ? Icons.gps_fixed : Icons.gps_not_fixed),
            tooltip: 'Detect GPS location',
            onPressed: _detectGpsLocation,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Location Bar ──
          _buildLocationBar(),
          // ── Search Bar ──
          _buildSearchBar(),
          // ── Content Area ──
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Location Bar (Dropdown + GPS indicator)
  // ---------------------------------------------------------------------------
  Widget _buildLocationBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.teal.shade50,
      child: Row(
        children: [
          Icon(
            _gpsActive ? Icons.gps_fixed : Icons.location_on,
            size: 16,
            color: Colors.teal.shade700,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _gpsActive
                    ? null
                    : chennaiAreas.indexWhere((a) => a.name == _locationLabel),
                hint: Text(
                  _locationLabel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.teal.shade800,
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
              foregroundColor: Colors.teal.shade700,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Search Bar with Auto-Suggestions
  // ---------------------------------------------------------------------------
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Search input
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  onSubmitted: _runComparison,
                  decoration: InputDecoration(
                    hintText: 'Search item (e.g. Amul Butter, Coke, Atta)',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _runComparison(_searchCtrl.text),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Compare'),
              ),
            ],
          ),

          // Suggestion chips
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
                    backgroundColor: Colors.teal.shade50,
                    side: BorderSide(color: Colors.teal.shade200),
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
  // Widget: Content Area (Loading / Error / Results / Empty)
  // ---------------------------------------------------------------------------
  Widget _buildContent() {
    // Loading state
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              'Searching 3 marts in $_locationLabel...',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 4),
            Text(
              'Calculating delivery + handling + GST',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
      );
    }

    // Error state with retry
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
                Icon(Icons.error_outline, color: Colors.red.shade400, size: 40),
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 14),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () => _runComparison(
                    _searchCtrl.text.isEmpty ? 'Amul Butter' : _searchCtrl.text,
                  ),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Try Again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Empty state (initial screen)
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shopping_cart_outlined, size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                'Search for a product to see the\ntrue landed cost across marts',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600),
              ),
              const SizedBox(height: 8),
              Text(
                'Item Price + Delivery + Handling + GST = Final Price',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    // Results list
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        return _buildMartCard(_results[index], isCheapest: index == 0);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Widget: Individual Mart Comparison Card
  // ---------------------------------------------------------------------------
  Widget _buildMartCard(Map<String, dynamic> item, {required bool isCheapest}) {
    final pricing = item['pricing'] as Map<String, dynamic>;

    return Card(
      elevation: isCheapest ? 2 : 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isCheapest ? Colors.green : Colors.grey.shade300,
          width: isCheapest ? 2.0 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: Platform name + badge
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  item['platform'] ?? '',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                if (isCheapest)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'CHEAPEST TOTAL',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${item['product_name']} • ${item['weight']}  —  ETA: ${item['eta']}',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
            ),

            const Divider(height: 18),

            // Fee breakdown rows
            _feeRow('Item Base Price', '₹${pricing['item_price']}'),
            _feeRow('Delivery Fee', '₹${pricing['delivery_fee']}'),
            _feeRow('Handling / Platform Fee', '₹${pricing['handling_fee']}'),
            _feeRow('GST on Fees (18%)', '₹${pricing['tax_on_fees']}'),

            const Divider(height: 18),

            // Final landed total
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Final Landed Price:',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                Text(
                  '₹${pricing['final_landed_price']}',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isCheapest ? Colors.green.shade800 : Colors.black87,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Deep link button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _openMartApp(
                  item['deep_link'] ?? '',
                  item['platform'] ?? '',
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text('Order on ${item['platform']}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isCheapest ? Colors.green.shade700 : Colors.grey.shade800,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feeRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade700)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
