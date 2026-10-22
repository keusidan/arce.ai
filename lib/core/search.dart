import 'dart:convert';

import 'http_get.dart';

class SearchHit {
  const SearchHit(this.title, this.url, this.snippet);
  final String title;
  final String url;
  final String snippet;
}

abstract interface class SearchProvider {
  String get name;
  Future<List<SearchHit>> search(String query, int limit);
}

String? _string(Object? value) => value is String ? value : null;

/// SearXNG's JSON API (`search.formats` must include `json` in its settings.yml).
class SearXngProvider implements SearchProvider {
  SearXngProvider(this.baseUrl, this._get);

  final String baseUrl;
  final HttpGet _get;

  @override
  String get name => 'SearXNG';

  @override
  Future<List<SearchHit>> search(String query, int limit) async {
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final body = await _get('$base/search?q=${Uri.encodeQueryComponent(query)}&format=json', const {});
    final root = jsonDecode(body);
    final results = root is Map ? root['results'] : null;
    final hits = <SearchHit>[];
    for (final element in (results is List ? results : const [])) {
      if (element is! Map) continue;
      final url = _string(element['url']);
      if (url == null) continue;
      hits.add(SearchHit(_string(element['title']) ?? url, url, _string(element['content']) ?? ''));
    }
    return hits.take(limit).toList();
  }
}

/// Brave Search's web search API: a real result list, with an API key (sent as a header, never kept
/// in the settings JSON). https://api.search.brave.com/res/v1/web/search?q=…&count=…
class BraveSearchProvider implements SearchProvider {
  BraveSearchProvider(this.apiKey, this._get);

  static const endpoint = 'https://api.search.brave.com/res/v1/web/search';

  final String apiKey;
  final HttpGet _get;

  @override
  String get name => 'Brave Search';

  @override
  Future<List<SearchHit>> search(String query, int limit) async {
    final count = limit.clamp(1, 20);
    final body = await _get(
      '$endpoint?q=${Uri.encodeQueryComponent(query)}&count=$count',
      {'Accept': 'application/json', 'X-Subscription-Token': apiKey},
    );
    final root = jsonDecode(body);
    final web = root is Map ? root['web'] : null;
    final results = web is Map ? web['results'] : null;
    final hits = <SearchHit>[];
    for (final element in (results is List ? results : const [])) {
      if (element is! Map) continue;
      final url = _string(element['url']);
      if (url == null) continue;
      hits.add(SearchHit(
        _plain(_string(element['title'])) ?? url,
        url,
        _plain(_string(element['description'])) ?? '',
      ));
    }
    return hits.take(limit).toList();
  }

  /// The snippets mark the matched words with tags and entities; the model needs only the text.
  static String? _plain(String? html) {
    if (html == null) return null;
    final text = html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .trim();
    return text.isEmpty ? null : text;
  }
}

/// DuckDuckGo's Instant Answer API: no key, but only abstracts and related topics, not a
/// full result list. Used as a fallback when the SearXNG server cannot be reached.
class DuckDuckGoInstantProvider implements SearchProvider {
  DuckDuckGoInstantProvider(this._get);

  final HttpGet _get;

  @override
  String get name => 'DuckDuckGo Instant Answer';

  @override
  Future<List<SearchHit>> search(String query, int limit) async {
    final body = await _get(
      'https://api.duckduckgo.com/?q=${Uri.encodeQueryComponent(query)}&format=json&no_html=1&skip_disambig=1',
      const {},
    );
    final root = jsonDecode(body);
    if (root is! Map) return const [];
    final hits = <SearchHit>[];
    final abstractUrl = _string(root['AbstractURL']);
    if (abstractUrl != null && abstractUrl.trim().isNotEmpty) {
      hits.add(SearchHit(_string(root['Heading']) ?? abstractUrl, abstractUrl, _string(root['AbstractText']) ?? ''));
    }
    void collect(Object? topics) {
      if (topics is! List) return;
      for (final t in topics) {
        if (t is! Map) continue;
        if (t['Topics'] != null) {
          collect(t['Topics']);
          continue;
        }
        final url = _string(t['FirstURL']);
        if (url == null) continue;
        final text = _string(t['Text']) ?? '';
        final title = text.split(' - ').first;
        hits.add(SearchHit(title.trim().isEmpty ? url : title, url, text));
      }
    }

    collect(root['RelatedTopics']);
    return hits.take(limit).toList();
  }
}

sealed class SearchOutcome {
  const SearchOutcome();
}

class SearchFound extends SearchOutcome {
  const SearchFound(this.provider, this.hits);
  final String provider;
  final List<SearchHit> hits;
}

class SearchFailed extends SearchOutcome {
  const SearchFailed(this.errors);
  final List<String> errors;
}

/// Tries providers in priority order (spec §10.1), retrying each up to [retriesPerProvider]
/// times, and removes duplicate pages. When every provider fails the caller continues with
/// the local model only.
class SearchService {
  SearchService(this.providers, {this.retriesPerProvider = 1, this.limit = 5});

  final List<SearchProvider> providers;
  final int retriesPerProvider;
  final int limit;

  Future<SearchOutcome> search(String query) async {
    final errors = <String>[];
    providers:
    for (final provider in providers) {
      for (var attempt = 0; attempt <= retriesPerProvider; attempt++) {
        try {
          final seen = <String>{};
          final hits = (await provider.search(query, limit * 2))
              .where((h) => seen.add(_normalize(h.url)))
              .take(limit)
              .toList();
          if (hits.isNotEmpty) return SearchFound(provider.name, hits);
          // an empty answer is not an error; retrying the same provider would not help
          errors.add('${provider.name}: no results');
          continue providers;
        } catch (e) {
          errors.add('${provider.name}: $e');
        }
      }
    }
    return SearchFailed(errors);
  }

  static String _normalize(String url) {
    var u = url.toLowerCase();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u.replaceFirst(RegExp(r'^https?://(www\.)?'), '');
  }
}
