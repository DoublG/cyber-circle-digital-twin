{{flutter_js}}
{{flutter_build_config}}

// The installation's network has no internet: the fonts Flutter falls back to
// for names in other scripts (Chinese, Hebrew, Hindi, emoji ...) come from the
// control server, next to the app (tools/assets/flutter_web_fonts.py), not
// from fonts.gstatic.com. (The engine itself: flutter build web --no-web-resources-cdn.)
_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    fontFallbackBaseUrl: new URL("fonts/fallback/", document.baseURI).href,
    useColorEmoji: true,                    // (Noto Color Emoji, only loaded when a name has one)
  },
});
