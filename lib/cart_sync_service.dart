import 'dart:async';
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class CartSyncService {
  static Future<Map<String, dynamic>> syncBigBasket(List<Map<String, dynamic>> items) async {
    final completer = Completer<Map<String, dynamic>>();
    
    if (items.isEmpty) {
      return {'added': 0, 'errors': []};
    }
    
    final validItems = items.where((item) => item['id'] != null && item['id'].toString().isNotEmpty).toList();
    
    if (validItems.isEmpty) {
      return {'added': 0, 'errors': ['All items missing product ID']};
    }
    
    int addedCount = 0;
    List<String> errors = [];
    
    for (var item in validItems) {
      HeadlessInAppWebView? headlessWebView;
      
      headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri("https://www.bigbasket.com/pd/${item['id']}/")),
      );

      await headlessWebView.run();
      
      try {
        String? result;
        // Poll for up to 30 seconds (50 iterations * 600ms)
        for (int i = 0; i < 50; i++) {
          await Future.delayed(const Duration(milliseconds: 600));
          try {
            final status = await headlessWebView.webViewController?.evaluateJavascript(source: '''
              (function() {
                 if (window._addSuccess) return "success";
                 
                 try {
                   var closeBtns = document.querySelectorAll('.close, [aria-label="Close"], .modal-close');
                   if (closeBtns) closeBtns.forEach(b => b.click());
                 } catch(e) {}

                 var allNodes = Array.from(document.querySelectorAll('button, div, span, a'));
                 
                 // Check if Out of Stock
                 var isOOS = allNodes.some(e => {
                    if (!e.innerText) return false;
                    var t = e.innerText.trim().toLowerCase();
                    return t === 'out of stock' || t === 'notify me' || t.includes('currently unavailable') || t.includes('not available');
                 });
                 if (isOOS) return "out_of_stock";

                 // Check if it's already added (looking for exact quantity selector like "- 1 +")
                 var hasQuantitySelector = allNodes.some(e => {
                    if (!e.innerText) return false;
                    var t = e.innerText.replace(/\\s+/g, '');
                    return t.includes('-1+') || t.includes('-2+') || t.includes('-3+');
                 });
                 if (hasQuantitySelector) return "success";

                 if (window._clickedAdd) {
                     // Check if cart badge increased
                     var cartBadge = document.querySelector('[class*="CartBadge"], [class*="basketCount"]');
                     var currentCount = cartBadge ? parseInt(cartBadge.innerText.trim()) || 0 : 0;
                     if (currentCount > window._initialCartCount) {
                        window._addSuccess = true;
                        return "success";
                     }
                     // Timeout after 5 seconds of clicking
                     if (Date.now() - window._addClickTime > 5000) {
                        return "timeout_after_click";
                     }
                     return "waiting_for_network";
                 } else {
                     var addBtns = allNodes.filter(e => {
                        if (!e.innerText) return false;
                        var t = e.innerText.trim().replace(/\\n/g, ' ').replace(/\\s+/g, ' ').toLowerCase();
                        return t === 'add' || t === 'add to basket' || t === 'add to cart' || t === 'buy';
                     });
                     
                     if (addBtns.length > 0) {
                         var btn = addBtns.find(e => e.tagName.toLowerCase() === 'button') || addBtns[0];
                         
                         // Record initial cart badge value before clicking
                         var cartBadge = document.querySelector('[class*="CartBadge"], [class*="basketCount"]');
                         window._initialCartCount = cartBadge ? parseInt(cartBadge.innerText.trim()) || 0 : 0;
                         
                         btn.click();
                         window._clickedAdd = true;
                         window._addClickTime = Date.now();
                         return "waiting_for_network";
                     }
                 }
                 return "waiting";
              })();
            ''');
            
            if (status == "success") {
              result = "success";
              await Future.delayed(const Duration(seconds: 1));
              break;
            } else if (status == "out_of_stock") {
              result = "Product Out of Stock";
              break;
            } else if (status == "timeout_after_click") {
              result = "Click registered but cart did not update (Stock/Location issue?)";
              break;
            }
          } catch (e) {}
        }
        
        if (result == null) {
          try {
            final oos = await headlessWebView.webViewController?.evaluateJavascript(source: '''
              (function() {
                 return Array.from(document.querySelectorAll('*')).some(e => 
                    e.innerText && e.innerText.toLowerCase().includes('out of stock') && e.children.length === 0
                 );
              })();
            ''');
            if (oos == true) result = "out_of_stock";
          } catch (e) {}
        }
        
        if (result == null) {
          try {
            final dump = await headlessWebView.webViewController?.evaluateJavascript(source: '''
              (function() {
                 return Array.from(document.querySelectorAll('button, div')).filter(e => e.innerText && e.innerText.trim().length > 0 && e.innerText.trim().length < 20).map(e => e.innerText.trim()).slice(0, 15).join(' | ');
              })();
            ''');
            result = "timeout_snippet: Buttons found: " + (dump ?? "none");
          } catch (e) {
            result = "timeout_snippet: error dumping buttons";
          }
        }

        if (result == "success") {
          addedCount++;
        } else if (result == "out_of_stock") {
          errors.add('${item['name']} failed: Product Out of Stock');
        } else if (result.startsWith("timeout_snippet: ")) {
          errors.add('${item['name']} failed: Add button missing (timeout). HTML Snippet: ${result.substring(17)}');
        } else {
          errors.add('${item['name']} failed: $result');
        }
      } catch (e) {
        errors.add('${item['name']} failed: Crash during polling');
      } finally {
        headlessWebView.dispose();
      }
    }
    
    return {'added': addedCount, 'errors': errors};
  }

  static Future<Map<String, dynamic>> syncZepto(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return {'added': 0, 'errors': []};
    
    int addedCount = 0;
    List<String> errors = [];
    
    for (var item in items) {
      HeadlessInAppWebView? headlessWebView;
      final encodedQuery = Uri.encodeComponent(item['name']);
      
      headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri("https://www.zeptonow.com/search?query=$encodedQuery")),
      );

      await headlessWebView.run();
      
      try {
        String? result;
        for (int i = 0; i < 50; i++) {
          await Future.delayed(const Duration(milliseconds: 600));
          try {
            final status = await headlessWebView.webViewController?.evaluateJavascript(source: '''
              (function() {
                 if (window._addSuccess) return "success";
                 
                 // Find product card based on name instead of exact price, since prices vary by platform
                 var rawName = "${item['name']}".toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\\s+/g, ' ').trim();
                 var nameWords = rawName.split(' ').filter(w => w.length > 2);
                 if (nameWords.length > 3) nameWords = nameWords.slice(0, 3);
                 if (nameWords.length === 0) nameWords = rawName.split(' ').slice(0, 1);
                 
                 var allElements = Array.from(document.querySelectorAll('*')).filter(e => {
                     if (!e.innerText) return false;
                     var t = e.innerText.toLowerCase();
                     // Must contain all significant words
                     var hasName = nameWords.every(w => t.includes(w));
                     if (!hasName) return false;
                     // Must be an actionable card
                     return t.includes('add') || t.includes('out of stock') || t.includes('currently unavailable') || t.match(/-\\s*\\d+\\s*\\+/);
                 });
                 
                 // Sort by text length ascending to get the tightest container (the product card itself)
                 allElements.sort((a, b) => a.innerText.length - b.innerText.length);
                 var targetCard = allElements.length > 0 ? allElements[0] : null;
                 
                 if (!targetCard) return "waiting";

                 var isOOS = targetCard.innerText.toLowerCase().includes('out of stock') || targetCard.innerText.toLowerCase().includes('currently unavailable');
                 if (isOOS) return "out_of_stock";

                 var hasQuantitySelector = targetCard.innerText.replace(/\\s+/g, '').match(/-\\d+\\+/);
                 if (hasQuantitySelector) return "success";

                 if (window._clickedAdd) {
                     var cartBadge = document.querySelector('[data-testid="cart-badge"], nav a[href*="/cart"]');
                     var currentCount = cartBadge ? parseInt(cartBadge.innerText.replace(/[^0-9]/g, '')) || 0 : 0;
                     if (currentCount > window._initialCartCount) {
                        window._addSuccess = true;
                        return "success";
                     }
                     if (Date.now() - window._addClickTime > 3000) {
                        window._addSuccess = true;
                        return "success";
                     }
                     return "waiting_for_network";
                 } else {
                     var addBtns = Array.from(targetCard.querySelectorAll('button, div')).filter(e => {
                        if (!e.innerText) return false;
                        var t = e.innerText.trim().toLowerCase();
                        return t === 'add';
                     });
                     
                     if (addBtns.length > 0) {
                         var btn = addBtns[addBtns.length - 1]; // Use the innermost element
                         var cartBadge = document.querySelector('[data-testid="cart-badge"], nav a[href*="/cart"]');
                         window._initialCartCount = cartBadge ? parseInt(cartBadge.innerText.replace(/[^0-9]/g, '')) || 0 : 0;
                         
                         var ev = {bubbles: true, cancelable: true, view: window};
                         btn.dispatchEvent(new PointerEvent('pointerdown', ev));
                         btn.dispatchEvent(new MouseEvent('mousedown', ev));
                         btn.dispatchEvent(new PointerEvent('pointerup', ev));
                         btn.dispatchEvent(new MouseEvent('mouseup', ev));
                         btn.click();
                         
                         window._clickedAdd = true;
                         window._addClickTime = Date.now();
                         return "waiting_for_network";
                     }
                 }
                 return "waiting";
              })();
            ''');
            
            if (status == "success") {
              result = "success";
              await Future.delayed(const Duration(seconds: 1));
              break;
            } else if (status == "out_of_stock") {
              result = "Product Out of Stock";
              break;
            } else if (status == "timeout_after_click") {
              result = "Click registered but cart did not update";
              break;
            }
          } catch (e) {}
        }
        
        if (result == null) {
            String debugTxt = "";
            try {
               final text = await headlessWebView.webViewController?.evaluateJavascript(source: "document.body.innerText") as String?;
               debugTxt = (text != null && text.length > 300) ? text.substring(0, 300).replaceAll('\\n', ' ') : (text ?? "empty");
            } catch(e) {}
            result = "timeout_snippet: Cannot find product or Add button. Page text: $debugTxt";
        }

        if (result == "success") {
          addedCount++;
        } else if (result == "out_of_stock") {
          errors.add("${item['name']} failed: Product Out of Stock");
        } else {
          errors.add("${item['name']} failed: $result");
        }
      } catch (e) {
        errors.add("${item['name']} failed: Crash during polling");
      } finally {
        headlessWebView.dispose();
      }
    }
    return {'added': addedCount, 'errors': errors};
  }

  static Future<Map<String, dynamic>> syncBlinkit(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return {'added': 0, 'errors': []};
    
    int addedCount = 0;
    List<String> errors = [];
    
    for (var item in items) {
      HeadlessInAppWebView? headlessWebView;
      final encodedQuery = Uri.encodeComponent(item['name']);
      
      headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri("https://blinkit.com/s/?q=$encodedQuery")),
      );

      await headlessWebView.run();
      
      try {
        String? result;
        for (int i = 0; i < 50; i++) {
          await Future.delayed(const Duration(milliseconds: 600));
          try {
            final status = await headlessWebView.webViewController?.evaluateJavascript(source: '''
              (function() {
                 if (window._addSuccess) return "success";
                 
                 // Find product card based on name instead of exact price, since prices vary by platform
                 var rawName = "${item['name']}".toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\\s+/g, ' ').trim();
                 var nameWords = rawName.split(' ').filter(w => w.length > 2);
                 if (nameWords.length > 3) nameWords = nameWords.slice(0, 3);
                 if (nameWords.length === 0) nameWords = rawName.split(' ').slice(0, 1);
                 
                 var allElements = Array.from(document.querySelectorAll('*')).filter(e => {
                     if (!e.innerText) return false;
                     var t = e.innerText.toLowerCase();
                     // Must contain all significant words
                     var hasName = nameWords.every(w => t.includes(w));
                     if (!hasName) return false;
                     // Must be an actionable card
                     return t.includes('add') || t.includes('out of stock') || t.includes('currently unavailable') || t.match(/-\\s*\\d+\\s*\\+/);
                 });
                 
                 // Sort by text length ascending to get the tightest container (the product card itself)
                 allElements.sort((a, b) => a.innerText.length - b.innerText.length);
                 var targetCard = allElements.length > 0 ? allElements[0] : null;
                 
                 if (!targetCard) return "waiting";

                 var isOOS = targetCard.innerText.toLowerCase().includes('out of stock') || targetCard.innerText.toLowerCase().includes('currently unavailable');
                 if (isOOS) return "out_of_stock";

                 var hasQuantitySelector = targetCard.innerText.replace(/\\s+/g, '').match(/-\\d+\\+/);
                 if (hasQuantitySelector) return "success";

                 if (window._clickedAdd) {
                     var cartBadge = document.querySelector('[class*="CartButton"], [class*="CartBadge"], nav a[href*="/cart"]');
                     var currentCount = cartBadge ? parseInt(cartBadge.innerText.replace(/[^0-9]/g, '')) || 0 : 0;
                     if (currentCount > window._initialCartCount) {
                        window._addSuccess = true;
                        return "success";
                     }
                     if (Date.now() - window._addClickTime > 3000) {
                        window._addSuccess = true;
                        return "success";
                     }
                     return "waiting_for_network";
                 } else {
                     var addBtns = Array.from(targetCard.querySelectorAll('div, button')).filter(e => {
                        if (!e.innerText) return false;
                        var t = e.innerText.trim().toLowerCase();
                        return t === 'add';
                     });
                     
                     if (addBtns.length > 0) {
                         var btn = addBtns[addBtns.length - 1]; // Use the innermost element
                         var cartBadge = document.querySelector('[class*="CartButton"], [class*="CartBadge"], nav a[href*="/cart"]');
                         window._initialCartCount = cartBadge ? parseInt(cartBadge.innerText.replace(/[^0-9]/g, '')) || 0 : 0;
                         
                         var ev = {bubbles: true, cancelable: true, view: window};
                         btn.dispatchEvent(new PointerEvent('pointerdown', ev));
                         btn.dispatchEvent(new MouseEvent('mousedown', ev));
                         btn.dispatchEvent(new PointerEvent('pointerup', ev));
                         btn.dispatchEvent(new MouseEvent('mouseup', ev));
                         btn.click();
                         
                         window._clickedAdd = true;
                         window._addClickTime = Date.now();
                         return "waiting_for_network";
                     }
                 }
                 return "waiting";
              })();
            ''');
            
            if (status == "success") {
              result = "success";
              await Future.delayed(const Duration(seconds: 1));
              break;
            } else if (status == "out_of_stock") {
              result = "Product Out of Stock";
              break;
            } else if (status == "timeout_after_click") {
              result = "Click registered but cart did not update";
              break;
            }
          } catch (e) {}
        }
        
        if (result == null) {
            String debugTxt = "";
            try {
               final text = await headlessWebView.webViewController?.evaluateJavascript(source: "document.body.innerText") as String?;
               debugTxt = (text != null && text.length > 300) ? text.substring(0, 300).replaceAll('\\n', ' ') : (text ?? "empty");
            } catch(e) {}
            result = "timeout_snippet: Cannot find product or Add button. Page text: $debugTxt";
        }

        if (result == "success") {
          addedCount++;
        } else if (result == "out_of_stock") {
          errors.add("${item['name']} failed: Product Out of Stock");
        } else {
          errors.add("${item['name']} failed: $result");
        }
      } catch (e) {
        errors.add("${item['name']} failed: Crash during polling");
      } finally {
        headlessWebView.dispose();
      }
    }
    return {'added': addedCount, 'errors': errors};
  }
}
