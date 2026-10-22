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

  test('brave search sends the key as a header and reads web.results', () async {
    const brave = '''{"web":{"results":[
      {"title":"Gemini <strong>API</strong> models","url":"https://ai.google.dev/models","description":"Latest &amp; stable <strong>models</strong>"},
      {"title":"No url"}]}}''';
    Map<String, String>? sent;
    String? asked;
    final provider = BraveSearchProvider('KEY', (url, headers) async {
      asked = url;
      sent = headers;
      return brave;
    });

    final hits = await provider.search('gemini api 最新', 5);
    expect(asked, startsWith('https://api.search.brave.com/res/v1/web/search?q='));
    expect(asked, isNot(contains('KEY')), reason: 'the key never goes into the URL');
    expect(sent!['X-Subscription-Token'], 'KEY');
    expect(hits, hasLength(1));
    expect(hits.single.title, 'Gemini API models');
    expect(hits.single.snippet, 'Latest & stable models');
  });

  test('brave comes before the instant answer when both are configured', () async {
    final service = SearchService([
      BraveSearchProvider('KEY', http({'api.search.brave.com': '{"web":{"results":[{"title":"T","url":"https://e.com/","description":"d"}]}}'})),
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
