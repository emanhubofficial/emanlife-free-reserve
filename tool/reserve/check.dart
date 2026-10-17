// One-shot check of a manifest against the providers' own public pages, for a person at a
// computer. It applies every verdict at once, with none of the scheduled policy's caution; the
// scheduled run (maintain.dart) is what publishes. Same sources, so the two cannot disagree.
//
//   dart run tool/reserve/check.dart <manifest.json in> <manifest.json out> <version> [--today YYYY-MM-DD]
import 'dart:convert';
import 'dart:io';

import 'reserve_sources.dart';

Future<void> main(List<String> args) async {
  final positional = [
    for (var i = 0; i < args.length; i++)
      if (!args[i].startsWith('--') && (i == 0 || args[i - 1] != '--today'))
        args[i],
  ];
  if (positional.length != 3) {
    stderr.writeln(
      'usage: dart run tool/reserve/check.dart <in.json> <out.json> <version> '
      '[--today YYYY-MM-DD]',
    );
    exit(64);
  }
  final todayFlag = args.indexOf('--today');
  final now = DateTime.now().toUtc();
  final today = todayFlag >= 0
      ? args[todayFlag + 1]
      : '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  final manifest =
      jsonDecode(File(positional[0]).readAsStringSync())
          as Map<String, dynamic>;
  final sources = await fetchSources(httpFetch);
  final report = <String>[];
  for (final m in (manifest['models'] as List).cast<Map<String, dynamic>>()) {
    final o = observe(m, sources);
    report.add(
      '${o.seen.name.padRight(11)} ${(m['provider'] as String).padRight(11)} '
      '${m['model']}  (${o.note})',
    );
    final evidence = m['evidence'] as Map<String, dynamic>;
    if (o.seen == Seen.confirmed) {
      evidence['verified_on'] = today;
    } else if (o.seen == Seen.absent || o.seen == Seen.notFree) {
      m['status'] = 'retired';
      m['status_note'] = 'Checked $today: ${o.note}. Source: ${o.source}';
    }
  }
  manifest['version'] = int.parse(positional[2]);
  manifest['issued_on'] = today;
  File(positional[1]).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  stdout.writeln(report.join('\n'));
  stdout.writeln('wrote ${positional[1]} (version ${positional[2]}, unsigned)');
}
