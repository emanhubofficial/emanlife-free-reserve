// Pre-flight for a signed free-reserve manifest, run by the publisher before anything goes live.
// It refuses what a phone would refuse, so a bad file is caught here and not discovered on a phone:
// a bad or untrusted signature, a version that does not rise, an unknown field, a credential-shaped
// value, a context below the 128K floor, evidence without an HTTPS source. The phone's own
// validator stays the authority; this only stops a doomed publication early.
//
//   dart run tool/reserve/verify.dart <manifest.json> <manifest.json.sig> <trusted_keys.json>
//        [--previous <manifest.json already published>]
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

const _topLevel = {
  'schema',
  'version',
  'issued_on',
  'models',
  'exclusions',
  'featured_providers',
  'screen',
};

final _secretLike = [
  RegExp(r'sk-[A-Za-z0-9_-]{20,}'),
  RegExp(r'AIza[0-9A-Za-z_-]{30,}'),
  RegExp(r'[Bb]earer\s+[A-Za-z0-9._~+/=-]{24,}'),
  RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
  RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
];

Future<List<String>> problems(
  List<int> bytes,
  String signature,
  List<Map<String, dynamic>> trusted, {
  int? previousVersion,
}) async {
  final out = <String>[];
  final parts = signature.trim().split(':');
  if (parts.length != 3 || parts[0] != 'ed25519') {
    out.add('the signature is not in the form ed25519:<id>:<base64>');
  } else {
    final key = trusted.where((k) => k['id'] == parts[1]).firstOrNull;
    if (key == null) {
      out.add('the signing key ${parts[1]} is not a trusted key');
    } else {
      try {
        final sig = base64Decode(parts[2]);
        final ok =
            sig.length == 64 &&
            await Ed25519().verify(
              bytes,
              signature: Signature(
                sig,
                publicKey: SimplePublicKey(
                  base64Decode(key['public_key'] as String),
                  type: KeyPairType.ed25519,
                ),
              ),
            );
        if (!ok) {
          out.add('the signature does not match the file');
        }
      } on Object {
        out.add('the signature is unreadable');
      }
    }
  }
  if (bytes.length > 400000) out.add('the file is larger than a phone accepts');
  final text = utf8.decode(bytes, allowMalformed: true);
  for (final pattern in _secretLike) {
    if (pattern.hasMatch(text)) {
      out.add('a credential-shaped value is in the file');
    }
  }
  Map<String, dynamic> json;
  try {
    json = jsonDecode(text) as Map<String, dynamic>;
  } on Object {
    return [...out, 'the file is not a JSON object'];
  }
  for (final k in json.keys) {
    if (!_topLevel.contains(k)) out.add('unknown field "$k"');
  }
  if (json['schema'] != 1) out.add('unknown schema ${json['schema']}');
  final version = json['version'];
  if (version is! int || version < 1) {
    out.add('version is not a positive integer');
  } else if (previousVersion != null && version <= previousVersion) {
    out.add(
      'version $version does not rise above the published $previousVersion',
    );
  }
  final models = json['models'];
  if (models is! List || models.isEmpty) {
    out.add('no models');
  } else {
    for (final m in models.cast<Map<String, dynamic>>()) {
      final name = '${m['provider']}/${m['model']}';
      if ((m['context'] as int? ?? 0) < 128000) {
        out.add('$name: context below 128K');
      }
      final evidence = m['evidence'];
      if (evidence is! Map ||
          !('${evidence['source']}'.contains('https://')) ||
          !RegExp(
            r'^\d{4}-\d{2}-\d{2}$',
          ).hasMatch('${evidence['verified_on']}')) {
        out.add('$name: evidence needs an https source and a date');
      }
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: verify.dart <manifest> <sig> <trusted_keys.json> [--previous <manifest>]',
    );
    exit(64);
  }
  final bytes = File(args[0]).readAsBytesSync();
  final signature = File(args[1]).readAsStringSync();
  final trusted = (jsonDecode(File(args[2]).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  int? previous;
  final i = args.indexOf('--previous');
  if (i >= 0 && File(args[i + 1]).existsSync()) {
    previous =
        (jsonDecode(File(args[i + 1]).readAsStringSync()) as Map)['version']
            as int?;
  }
  final found = await problems(
    bytes,
    signature,
    trusted,
    previousVersion: previous,
  );
  if (found.isEmpty) {
    stdout.writeln('verified: signature trusted, version ok, schema ok');
    return;
  }
  for (final p in found) {
    stderr.writeln('REFUSED: $p');
  }
  exit(1);
}
