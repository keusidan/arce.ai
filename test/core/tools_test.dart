import 'package:arce_ai/core/http_get.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/search.dart';
import 'package:arce_ai/core/tool_runtime.dart';
import 'package:arce_ai/core/weather.dart';
import 'package:flutter_test/flutter_test.dart';

HttpGet http(Map<String, String> routes) => (url, _) async {
      for (final entry in routes.entries) {
        if (url.contains(entry.key)) return entry.value;
      }
      throw HttpStatusException(404, 'no route for $url');
    };

const searxJson = '''{"results":[
  {"url":"https://example.com/a","title":"A","content":"alpha"},
  {"url":"https://www.example.com/a/","title":"A dup","content":"dup"},
  {"url":"https://example.org/b","title":"B","content":"beta"}]}''';

void main() {
  test('searxng results are parsed and duplicates removed', () async {
    final service = SearchService([SearXngProvider('http://pi:8080/', http({'pi:8080/search': searxJson}))]);
    final found = await service.search('q') as SearchFound;
    expect(found.hits.map((h) => h.url), ['https://example.com/a', 'https://example.org/b']);
  });

  test('falls back to the next provider and finally reports failure', () async {
    const ddg = '{"Heading":"Kotlin","AbstractURL":"https://kotlinlang.org","AbstractText":"A language","RelatedTopics":[]}';
    final service = SearchService(
      [SearXngProvider('http://pi', http({})), DuckDuckGoInstantProvider(http({'duckduckgo': ddg}))],
    );
    final found = await service.search('kotlin') as SearchFound;
    expect(found.provider, 'DuckDuckGo Instant Answer');

    final none = SearchService([SearXngProvider('http://pi', http({}))]);
    final failed = await none.search('x') as SearchFailed;
    expect(failed.errors, hasLength(2), reason: 'one try plus one retry');
  });

  SearchApiConfig brave() => SearchApiConfig.presets['Brave Search']!.copyWith(name: 'Brave Search');

  test('a configured search API puts the key in the header and reads the results path', () async {
    const body = '''{"web":{"results":[
      {"title":"Gemini <strong>API</strong> models","url":"https://ai.google.dev/models","description":"Latest &amp; stable <strong>models</strong>"},
      {"title":"No url"}]}}''';
    Map<String, String>? sent;
    String? asked;
    final provider = ConfiguredSearchProvider(brave(), 'KEY', (url, headers) async {
      asked = url;
      sent = headers;
      return body;
    });

    final hits = await provider.search('gemini api 最新', 5);
    expect(asked, startsWith('https://api.search.brave.com/res/v1/web/search?q='));
    expect(asked, contains('count=5'));
    expect(asked, isNot(contains('KEY')), reason: 'the key stays in the header here');
    expect(sent!['X-Subscription-Token'], 'KEY');
    expect(hits, hasLength(1));
    expect(hits.single.title, 'Gemini API models');
    expect(hits.single.snippet, 'Latest & stable models');
  });

  test('{key} in the address is filled and encoded, and other field names can be used', () async {
    String? asked;
    final provider = ConfiguredSearchProvider(
      const SearchApiConfig(
        id: 'g',
        name: 'Google',
        url: 'https://www.googleapis.com/customsearch/v1?key={key}&cx=abc&q={query}&num={count}',
        resultsPath: 'items',
        urlField: 'link',
        snippetField: 'snippet',
      ),
      'k&1',
      (url, headers) async {
        asked = url;
        return '{"items":[{"title":"T","link":"https://e.com/","snippet":"s"}]}';
      },
    );
    final hits = await provider.search('a b', 3);
    expect(asked, contains('key=k%261'));
    expect(asked, contains('q=a+b'));
    expect(hits.single.url, 'https://e.com/');
    expect(hits.single.snippet, 's');
  });

  test('a service that needs a key says so instead of calling it without one', () async {
    var called = false;
    final provider = ConfiguredSearchProvider(brave(), ' ', (url, headers) async {
      called = true;
      return '{}';
    });
    await expectLater(provider.search('q', 3), throwsA(isA<StateError>()));
    expect(called, isFalse);
  });

  test('an answer that is the list itself needs no results path', () async {
    final provider = ConfiguredSearchProvider(
      const SearchApiConfig(id: 'x', name: 'X', url: 'https://x.example/s?q={query}', snippetField: 'text'),
      '',
      (url, headers) async => '[{"title":"A","url":"https://a.example/","text":"t"}]',
    );
    expect((await provider.search('q', 3)).single.snippet, 't');
  });

  test('headers: a secret-looking name must take its value from {key}', () {
    expect(SearchApiConfig.parseHeaders('{"X-Subscription-Token": "{key}"}'), {'X-Subscription-Token': '{key}'});
    expect(SearchApiConfig.parseHeaders(''), isEmpty);
    expect(() => SearchApiConfig.parseHeaders('{"Authorization": "Bearer abc"}'), throwsFormatException);
    expect(() => SearchApiConfig.parseHeaders('not json'), throwsFormatException);
  });

  test('the config survives a round trip and never has a key field', () {
    final back = SearchApiConfig.fromJson(brave().copyWith(name: 'B').toJson());
    expect(back.url, brave().url);
    expect(back.headers['X-Subscription-Token'], '{key}');
    expect(back.resultsPath, 'web.results');
    expect(back.toJson().keys, isNot(contains('key')));
    expect(SearchApis.idFor('Brave Search', const []), 'brave-search');
    expect(SearchApis.idFor('日本語', const []), 'search');
  });

  test('configured providers come before the instant answer', () async {
    final service = SearchService([
      ConfiguredSearchProvider(brave(), 'KEY', http({'api.search.brave.com': '{"web":{"results":[{"title":"T","url":"https://e.com/","description":"d"}]}}'})),
      DuckDuckGoInstantProvider(http({})),
    ]);
    expect((await service.search('q') as SearchFound).provider, 'Brave Search');
  });

  test('a failed search carries the hint about what to set', () async {
    final runtime = DefaultToolRuntime(
      search: SearchService([DuckDuckGoInstantProvider(http({'duckduckgo': '{}'}))]),
      searchHint: 'Brave のキーを入れてください',
    );
    final out = await runtime.run(const WebSearch('x'));
    expect(out.activity.failed, isTrue);
    expect(out.activity.summary, contains('Brave のキーを入れてください'));
    expect(out.response, contains('Brave のキーを入れてください'));
  });

  test('weather combines geocoding and forecast', () async {
    final weather = OpenMeteoWeather(http({
      'geocoding-api':
          '{"results":[{"name":"東京","admin1":"東京都","country":"日本","latitude":35.68,"longitude":139.69}]}',
      'api.open-meteo.com': '{"current":{"temperature_2m":21.5,"weather_code":3,"wind_speed_10m":7.2},'
          '"daily":{"temperature_2m_max":[24.0],"temperature_2m_min":[18.1]}}',
    }));
    final report = await weather.report('東京');
    expect(report.place, '東京, 東京都, 日本');
    expect(report.description, '曇り');
    expect(report.todayMaxC, 24.0);
  });

  test('runtime answers time in the requested zone and reports search failure softly', () async {
    DateTime clock() => DateTime.utc(2026, 9, 26, 12);
    final runtime = DefaultToolRuntime(
      search: SearchService([SearXngProvider('http://pi', http({}))]),
      clock: clock,
    );

    final time = await runtime.run(const GetTime('Asia/Tokyo'));
    expect(time.response, allOf(contains('2026-09-26'), contains('21:00:00')));

    final search = await runtime.run(const WebSearch('x'));
    expect(search.activity.failed, isTrue);
    expect(search.response, contains('own knowledge'));

    final offline = await DefaultToolRuntime(clock: clock).run(const WebSearch('x'));
    expect(offline.activity.failed, isTrue);
    expect(offline.response.trim(), isNotEmpty);
  });
}
