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
  bool _isZeptoLinked = false;
  bool _isBlinkitLinked = false;
  bool _showWebView = false;
  String _currentLoginPlatform = '';
  
  InAppWebViewController? webViewController;
  CookieManager cookieManager = CookieManager.instance();

  @override
  void initState() {
    super.initState();
    _checkLinkedStatus();
  }

  Future<void> _checkLinkedStatus() async {
    final linkedB = await _storage.read(key: 'bigbasket_linked');
    final linkedZ = await _storage.read(key: 'zepto_linked');
    final linkedBk = await _storage.read(key: 'blinkit_linked');
    setState(() {
      _isBLinked = linkedB == 'true';
      _isZeptoLinked = linkedZ == 'true';
      _isBlinkitLinked = linkedBk == 'true';
    });
  }

  Future<void> _unlink(String platform) async {
    if (platform == 'BigBasket') {
      await cookieManager.deleteCookies(url: WebUri("https://www.bigbasket.com/"));
      await _storage.delete(key: 'bigbasket_linked');
      setState(() => _isBLinked = false);
    } else if (platform == 'Zepto') {
      await cookieManager.deleteCookies(url: WebUri("https://www.zeptonow.com/"));
      await _storage.delete(key: 'zepto_linked');
      setState(() => _isZeptoLinked = false);
    } else if (platform == 'Blinkit') {
      await cookieManager.deleteCookies(url: WebUri("https://blinkit.com/"));
      await _storage.delete(key: 'blinkit_linked');
      setState(() => _isBlinkitLinked = false);
    }
  }

  void _onLoginSuccess(String platform) async {
    if (platform == 'BigBasket') {
      await _storage.write(key: 'bigbasket_linked', value: 'true');
      setState(() => _isBLinked = true);
    } else if (platform == 'Zepto') {
      await _storage.write(key: 'zepto_linked', value: 'true');
      setState(() => _isZeptoLinked = true);
    } else if (platform == 'Blinkit') {
      await _storage.write(key: 'blinkit_linked', value: 'true');
      setState(() => _isBlinkitLinked = true);
    }
    setState(() {
      _showWebView = false;
      _currentLoginPlatform = '';
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$_currentLoginPlatform account linked successfully!')));
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
            title: Text('Login to $_currentLoginPlatform'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _showWebView = false),
            ),
            actions: [
              TextButton(
                onPressed: () => _onLoginSuccess(_currentLoginPlatform),
                child: const Text('Done', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ],
          ),
          body: InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri(
                _currentLoginPlatform == 'BigBasket' ? "https://www.bigbasket.com/auth/login/" :
                _currentLoginPlatform == 'Zepto' ? "https://www.zeptonow.com/" :
                "https://blinkit.com/"
              )
            ),
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
              if (uri != null && uri.scheme == 'martprice' && uri.host == 'login-success') {
                final platform = uri.queryParameters['platform'];
                if (platform != null) {
                  _onLoginSuccess(platform);
                }
                return NavigationActionPolicy.CANCEL;
              }
              if (uri != null && !["http", "https", "file", "chrome", "data", "javascript", "about"].contains(uri.scheme)) {
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onLoadStop: (controller, url) async {
              if (url == null) return;
              
              if (_currentLoginPlatform == 'BigBasket') {
                final isLoggedIn = await controller.evaluateJavascript(source: '''
                  (function() {
                     var cookies = document.cookie;
                     if (cookies.includes('_bb_uid=')) return true;
                     if (window.location.pathname !== '/auth/login/') {
                        var links = Array.from(document.querySelectorAll('a, button'));
                        var hasLoginLink = links.some(e => 
                           (e.href && e.href.includes('/auth/login')) || 
                           (e.innerText && (e.innerText.toLowerCase().includes('login') || e.innerText.toLowerCase() === 'sign up'))
                        );
                        if (!hasLoginLink) return true;
                     }
                     return false;
                  })();
                ''');
                if (isLoggedIn == true) _onLoginSuccess('BigBasket');
              } else if (_currentLoginPlatform == 'Zepto') {
                await controller.evaluateJavascript(source: '''
                  setInterval(function() {
                     try {
                       var links = Array.from(document.querySelectorAll('a, button'));
                       var hasProfile = links.some(e => (e.href && e.href.includes('/profile')) || (e.innerText && e.innerText.toLowerCase().includes('profile')));
                       if (hasProfile) {
                           window.location.href = "martprice://login-success?platform=Zepto";
                       }
                     } catch(e) {}
                  }, 2000);
                ''');
              } else if (_currentLoginPlatform == 'Blinkit') {
                await controller.evaluateJavascript(source: '''
                  setInterval(function() {
                     try {
                       var links = Array.from(document.querySelectorAll('a, button'));
                       var hasProfile = links.some(e => (e.href && (e.href.includes('/account') || e.href.includes('/profile'))) || (e.innerText && (e.innerText.toLowerCase().includes('profile') || e.innerText.toLowerCase().includes('my account'))));
                       if (hasProfile) {
                           window.location.href = "martprice://login-success?platform=Blinkit";
                       }
                     } catch(e) {}
                  }, 2000);
                ''');
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
          const SizedBox(height: 16),
          _buildPlatformCard('Zepto', _isZeptoLinked, const Color(0xFF330066)),
          const SizedBox(height: 16),
          _buildPlatformCard('Blinkit', _isBlinkitLinked, const Color(0xFFF5C518)),
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
                  onPressed: () => _unlink(name),
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
                  setState(() {
                    _currentLoginPlatform = name;
                    _showWebView = true;
                  });
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
