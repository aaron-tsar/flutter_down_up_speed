library speed_test_dart;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:speed_test_dart/classes/classes.dart';
import 'package:speed_test_dart/constants.dart';
import 'package:speed_test_dart/enums/file_size.dart';
import 'package:sync/sync.dart';
import 'package:xml/xml.dart';

/// A Speed tester.
class SpeedTestDart {
  /// Create a Client for the requests
  http.Client createCustomClient({
    final String? userAgent = 'AppleWebKit/537.36 (KHTML, like Gecko)',
  }) {
    // Initialize a (lower-level) HttpClient from dart:io with a custom user agent.
    // (Don't use this directly).
    final innerClient = HttpClient()..userAgent = userAgent;

    // Pass the lower-level client into an IOClient object (from the http package).
    return IOClient(innerClient);
  }

  /// Returns [Settings] from speedtest.net.
  Future<Settings> getSettings() async {
    final client = createCustomClient();

    final response = await client.get(Uri.parse(configUrl));
    final settings = Settings.fromXMLElement(
      XmlDocument.parse(response.body).getElement('settings'),
    );

    var serversConfig = ServersList(<Server>[]);
    for (final element in serversUrls) {
      if (serversConfig.servers.isNotEmpty) break;
      try {
        final resp = await client.get(Uri.parse(element));

        serversConfig = ServersList.fromXMLElement(
          XmlDocument.parse(resp.body).getElement('settings'),
        );
      } catch (ex) {
        serversConfig = ServersList(<Server>[]);
      }
    }

    final ignoredIds = settings.serverConfig.ignoreIds.split(',');
    serversConfig.calculateDistances(settings.client.geoCoordinate);
    settings.servers = serversConfig.servers
        .where(
          (s) => !ignoredIds.contains(s.id.toString()),
    )
        .toList();
    settings.servers.sort((a, b) => a.distance.compareTo(b.distance));

    return settings;
  }

  /// Returns a List[Server] with the best servers, ordered
  /// by lowest to highest latency.
  Future<List<Server>> getBestServers({
    required List<Server> servers,
    int retryCount = 2,
    int timeoutInSeconds = 2,
  }) async {
    final client = createCustomClient();
    List<Server> serversToTest = [];

    for (final server in servers) {
      final latencyUri = createTestUrl(server, 'latency.txt');
      final stopwatch = Stopwatch();

      stopwatch.start();
      try {
        await client.get(latencyUri).timeout(
          Duration(
            seconds: timeoutInSeconds,
          ),
          onTimeout: (() => http.Response(
            '999999999',
            500,
          )),
        );
        // If a server fails the request, continue in the iteration
      } catch (_) {
        continue;
      } finally {
        stopwatch.stop();
      }

      final latency = stopwatch.elapsedMilliseconds / retryCount;
      if (latency < 500) {
        server.latency = latency;
        serversToTest.add(server);
      }
    }

    serversToTest.sort((a, b) => a.latency.compareTo(b.latency));

    return serversToTest;
  }

  /// Creates [Uri] from [Server] and [String] file
  Uri createTestUrl(Server server, String file) {
    return Uri.parse(
      Uri.parse(server.url).toString().replaceAll('upload.php', file),
    );
  }

  /// Returns urls for download test.
  List<String> generateDownloadUrls(
      Server server,
      int retryCount,
      List<FileSize> downloadSizes,
      ) {
    final downloadUriBase = createTestUrl(server, 'random{0}x{0}.jpg?r={1}');
    final result = <String>[];
    for (final ds in downloadSizes) {
      for (var i = 0; i < retryCount; i++) {
        result.add(
          downloadUriBase
              .toString()
              .replaceAll('%7B0%7D', FILE_SIZE_MAPPING[ds].toString())
              .replaceAll('%7B1%7D', i.toString()),
        );
      }
    }
    return result;
  }

  /// Returns [double] downloaded speed in MB/s.
  Future<double> testDownloadSpeed({
    required List<Server> servers,
    int simultaneousDownloads = 2,
    int retryCount = 3,
    List<FileSize> downloadSizes = defaultDownloadSizes,
  }) async {
    final client = createCustomClient();
    double downloadSpeed = 0;

    // Iterates over all servers, if one request fails, the next one is tried.
    for (final s in servers) {
      final testData = generateDownloadUrls(s, retryCount, downloadSizes);
      final semaphore = Semaphore(simultaneousDownloads);
      final tasks = <int>[];
      final stopwatch = Stopwatch()..start();

      try {
        await Future.forEach(testData, (String td) async {
          await semaphore.acquire();
          try {
            final data = await client.get(Uri.parse(td));
            tasks.add(data.bodyBytes.length);
          } finally {
            semaphore.release();
          }
        });
        stopwatch.stop();
        final _totalSize = tasks.reduce((a, b) => a + b);
        downloadSpeed = (_totalSize * 8 / 1024) /
            (stopwatch.elapsedMilliseconds / 1000) /
            1000;
        break;
      } catch (_) {
        continue;
      }
    }
    return downloadSpeed;
  }

  /// Returns [double] upload speed in MB/s.
  Future<double> testUploadSpeed({
    required List<Server> servers,
    int simultaneousUploads = 2,
    int retryCount = 3,
  }) async {
    double uploadSpeed = 0;
    for (var s in servers) {
      final testData = generateUploadData(retryCount);
      final semaphore = Semaphore(simultaneousUploads);
      final stopwatch = Stopwatch()..start();
      final tasks = <int>[];

      try {
        await Future.forEach(testData, (String td) async {
          await semaphore.acquire();
          try {
            // do post request to measure time for upload
            await http.post(Uri.parse(s.url), body: td);
            tasks.add(td.length);
          } finally {
            semaphore.release();
          }
        });
        stopwatch.stop();
        final _totalSize = tasks.reduce((a, b) => a + b);
        uploadSpeed = (_totalSize * 8 / 1024) /
            (stopwatch.elapsedMilliseconds / 1000) /
            1000;
        break;
      } catch (_) {
        continue;
      }
    }
    return uploadSpeed;
  }

  /// Generate list of [String] urls for upload.
  List<String> generateUploadData(int retryCount) {
    final random = Random();
    final result = <String>[];

    for (var sizeCounter = 1; sizeCounter < maxUploadSize + 1; sizeCounter++) {
      final size = sizeCounter * 200 * 1024;
      final builder = StringBuffer()
        ..write('content ${sizeCounter.toString()}=');

      for (var i = 0; i < size; ++i) {
        builder.write(hars[random.nextInt(hars.length)]);
      }

      for (var i = 0; i < retryCount; i++) {
        result.add(builder.toString());
      }
    }

    return result;
  }
}