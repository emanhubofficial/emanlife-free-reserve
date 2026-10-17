// Signs a free-reserve manifest file.
//
//   dart run tool/reserve/sign.dart <manifest.json> <private key file | env:VARIABLE> <key id>
//
// Writes <manifest.json>.sig next to it, in the format the app verifies:
//   ed25519:<key id>:<base64 signature over the exact file bytes>
//
// The key is a base64 seed. `env:NAME` reads it from an environment variable (how the scheduled
// workflow holds it, so it is never written to disk); it is never printed.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run tool/reserve/sign.dart <manifest> <key file|env:NAME> <id>',
    );
    exit(64);
  }
  final manifest = File(args[0]);
  final bytes = manifest.readAsBytesSync();
  final String raw;
  if (args[1].startsWith('env:')) {
    raw = Platform.environment[args[1].substring(4)] ?? '';
    if (raw.trim().isEmpty) {
      stderr.writeln('the signing key variable is empty');
      exit(78);
    }
  } else {
    raw = File(args[1]).readAsStringSync();
  }
  final seed = base64Decode(raw.trim());
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final signature = await Ed25519().sign(bytes, keyPair: pair);
  final out = File(
    '${args[0]}.sig',
  )..writeAsStringSync('ed25519:${args[2]}:${base64Encode(signature.bytes)}\n');
  stdout.writeln('wrote ${out.path}');
}
