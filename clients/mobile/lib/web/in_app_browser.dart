import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Open [url] in an in-app browser (a WKWebView on iOS / Android WebView) so Capecho's legal + contact
/// pages read INSIDE the app rather than bouncing the user out to Safari/Chrome. Pushed as a full route
/// over whatever surface opened it (e.g. the Settings popover); dismissed with the header's close button
/// or the system back gesture. A header "open in browser" action remains for anyone who wants the real
/// browser (and is the graceful path if the page misbehaves in a WebView).
void openInAppBrowser(BuildContext context, {required Uri url, required String title}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _InAppBrowserScreen(url: url, title: title),
    ),
  );
}

class _InAppBrowserScreen extends StatefulWidget {
  const _InAppBrowserScreen({required this.url, required this.title});

  final Uri url;
  final String title;

  @override
  State<_InAppBrowserScreen> createState() => _InAppBrowserScreenState();
}

class _InAppBrowserScreenState extends State<_InAppBrowserScreen> {
  late final WebViewController _controller;

  /// 0–100 load progress; hidden once the page finishes so the warm chrome isn't permanently striped.
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _progress = 100);
          },
        ),
      )
      ..loadRequest(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final loading = _progress > 0 && _progress < 100;
    return Scaffold(
      backgroundColor: p.canvas,
      body: SafeArea(
        child: Column(
          children: [
            _header(p),
            // A hairline + a thin progress sliver while the page loads (no spinner over the content).
            SizedBox(
              height: 2,
              child: loading
                  ? LinearProgressIndicator(
                      value: _progress / 100,
                      minHeight: 2,
                      backgroundColor: p.line,
                      valueColor: AlwaysStoppedAnimation<Color>(p.primary),
                    )
                  : Divider(height: 2, thickness: 1, color: p.line),
            ),
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      ),
    );
  }

  /// Close (left) · title + host (center) · open-in-browser (right). The host reassures the reader which
  /// site they're on inside the app.
  Widget _header(OnboardingPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, size: 22, color: p.ink2),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.chrome(size: 15, weight: FontWeight.w600, color: p.ink),
                ),
                Text(
                  widget.url.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: p.mono(size: 11, color: p.ink3),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.open_in_new, size: 20, color: p.ink2),
            tooltip: 'Open in browser',
            onPressed: () => capechoOpenExternal(widget.url),
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
        ],
      ),
    );
  }
}
