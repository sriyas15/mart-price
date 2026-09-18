import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LinkAccountsScreen extends StatefulWidget {
  const LinkAccountsScreen({super.key});

  @override
  State<LinkAccountsScreen> createState() => _LinkAccountsScreenState();
}

class _LinkAccountsScreenState extends State<LinkAccountsScreen> {
  final _storage = const FlutterSecureStorage();
  bool _isBLinked = false;
  bool _showWebView = false;
  
  InAppWebViewController? webViewController;
  CookieManager cookieManager = CookieManager.instance();

  @override
  void initState() {
    super.initState();
    _checkLinkedStatus();
  }

  Future<void> _checkLinkedStatus() async {
    final linked = await _storage.read(key: 'bigbasket_linked');
    setState(() {
      _isBLinked = linked == 'true';
    });
  }

  Future<void> _unlink() async {
    // Clear cookies for bigbasket
    await cookieManager.deleteAllCookies();
    await _storage.delete(key: 'bigbasket_linked');
    setState(() {
      _isBLinked = false;
    });
  }

  void _onLoginSuccess() async {
    // We assume login is successful when the url changes away from /login/ 
    // or when we detect the session cookie.
    await _storage.write(key: 'bigbasket_linked', value: 'true');
    setState(() {
      _isBLinked = true;
      _showWebView = false;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account linked successfully!')));
  }

  @override
  Widget build(BuildContext context) {
    if (_showWebView) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          setState(() => _showWebView = false);
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Login to BigBasket'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _showWebView = false),
            ),
            actions: [
              TextButton(
                onPressed: _onLoginSuccess,
                child: const Text('Done', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
          body: InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri("https://www.bigbasket.com/auth/login/")),
            initialSettings: InAppWebViewSettings(
              userAgent: "Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.79 Mobile Safari/537.36",
              javaScriptEnabled: true,
              thirdPartyCookiesEnabled: true,
              useShouldOverrideUrlLoading: true,
            ),
            onWebViewCreated: (controller) {
              webViewController = controller;
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              var uri = navigationAction.request.url;
              if (uri != null && !["http", "https", "file", "chrome", "data", "javascript", "about"].contains(uri.scheme)) {
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onLoadStop: (controller, url) async {
              if (url == null) return;
              
              // Automatically detect if the user is logged in
              final isLoggedIn = await controller.evaluateJavascript(source: '''
                (function() {
                   var cookies = document.cookie;
                   // BigBasket usually sets _bb_uid for logged-in users
                   if (cookies.includes('_bb_uid=')) return true;
                   
                   // If we are not on the login page anymore
                   if (window.location.pathname !== '/auth/login/') {
                      // Check if there's any login link on the page
                      var links = Array.from(document.querySelectorAll('a, button'));
                      var hasLoginLink = links.some(e => 
                         (e.href && e.href.includes('/auth/login')) || 
                         (e.innerText && (e.innerText.toLowerCase().includes('login') || e.innerText.toLowerCase() === 'sign up'))
                      );
                      
                      // If there is no login link on the homepage/other page, they are authenticated
                      if (!hasLoginLink) return true;
                   }
                   return false;
                })();
              ''');

              if (isLoggedIn == true) {
                _onLoginSuccess();
              }
            },
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Link Accounts'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 1,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Connect your store accounts to instantly auto-fill your cart in the background!',
            style: TextStyle(fontSize: 16, color: Colors.black87),
          ),
          const SizedBox(height: 32),
          
          _buildPlatformCard('BigBasket', _isBLinked, const Color(0xFF689f38)),
        ],
      ),
    );
  }

  Widget _buildPlatformCard(String name, bool isLinked, Color brandColor) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: isLinked ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                name,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: brandColor),
              ),
              const Spacer(),
              if (isLinked)
                TextButton(
                  onPressed: _unlink,
                  child: const Text('Unlink', style: TextStyle(color: Colors.red)),
                )
            ],
          ),
          const SizedBox(height: 16),
          
          if (isLinked)
            const Text('Account successfully linked! You can now use Auto-Fill Cart.', style: TextStyle(color: Colors.green, fontWeight: FontWeight.w500))
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  setState(() => _showWebView = true);
                },
                icon: const Icon(Icons.login),
                label: const Text('Login to Link'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: brandColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
