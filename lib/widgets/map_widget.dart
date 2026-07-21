import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:latlong2/latlong.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:http_cache_file_store/http_cache_file_store.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class MapWidget extends StatefulWidget {
  final Map<String, dynamic> contributorData;

  const MapWidget({super.key, required this.contributorData});

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  static const _maxCacheAge = Duration(days: 7);
  static const _maxCacheBytes = 90 * 1024 * 1024;

  int _tileErrorCount = 0;
  int _reloadToken = 0;
  FileCacheStore? _cacheStore;
  Timer? _cacheCleanupTimer;

  @override
  void initState() {
    super.initState();
    _initTileCache();
  }

  Future<void> _initTileCache() async {
    try {
      final dir = await getTemporaryDirectory();
      final cacheDirectory = Directory(
        '${dir.path}${Platform.pathSeparator}MapTiles',
      );
      final store = FileCacheStore(cacheDirectory.path);
      await _trimTileCache(cacheDirectory);
      if (!mounted) {
        await store.close();
        return;
      }
      setState(() => _cacheStore = store);
      _cacheCleanupTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => _trimTileCache(cacheDirectory),
      );
    } catch (_) {
      // If cache initialization fails, we fall back to uncached tiles.
    }
  }

  Future<void> _trimTileCache(Directory directory) async {
    try {
      if (!await directory.exists()) return;

      final files = <File>[];
      var totalBytes = 0;
      await for (final entity
          in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          totalBytes += await entity.length();
          files.add(entity);
        }
      }
      if (totalBytes <= _maxCacheBytes) return;

      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      for (final file in files) {
        if (totalBytes <= _maxCacheBytes) break;
        final length = await file.length();
        await file.delete();
        totalBytes -= length;
      }
    } catch (_) {
      // Cache cleanup is best-effort and should never prevent showing a map.
    }
  }

  @override
  void dispose() {
    _cacheCleanupTimer?.cancel();
    _cacheStore?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<LatLng>>(
      future: _getAirportCoordinates(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return CircularProgressIndicator(
            backgroundColor: Theme.of(context).colorScheme.surface,
          );
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Text('No map data available');
        }
        if (_cacheStore == null) {
          return CircularProgressIndicator(
            backgroundColor: Theme.of(context).colorScheme.surface,
          );
        }

        List<LatLng> points = snapshot.data!;
        LatLngBounds bounds = LatLngBounds.fromPoints(points);

        // We use dotenv (runtime-loaded `.env`) so production builds can read the
        // Stadia key without requiring compile-time `--dart-define`.
        final stadiaApiKey = dotenv.env['STADIA_MAPS_API_KEY'] ?? '';
        const stadiaUrlTemplateBase =
            'https://tiles.stadiamaps.com/tiles/alidade_smooth/{z}/{x}/{y}{r}.png';
        final stadiaUrlTemplate = stadiaApiKey.isNotEmpty
            ? '$stadiaUrlTemplateBase?api_key={api_key}'
            : stadiaUrlTemplateBase;

        return Container(
          height: 200,
          margin: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(
                color: const Color.fromARGB(255, 180, 221, 255), width: 4),
            borderRadius: BorderRadius.circular(30),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: Stack(
              children: [
                FlutterMap(
                  options: MapOptions(
                    initialCameraFit: CameraFit.bounds(
                      bounds: bounds,
                      padding: const EdgeInsets.all(20),
                    ),
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.pinchZoom |
                          InteractiveFlag.pinchMove |
                          InteractiveFlag.doubleTapZoom,
                      enableMultiFingerGestureRace: true,
                    ),
                  ),
                  children: [
                    TileLayer(
                      key: ValueKey(_reloadToken),
                      urlTemplate: stadiaUrlTemplate,
                      additionalOptions: stadiaApiKey.isNotEmpty
                          ? {'api_key': stadiaApiKey}
                          : const {},
                      maxZoom: 20,
                      tileProvider: CachedTileProvider(
                        store: _cacheStore!,
                        // Honor the provider's HTTP caching rules and never
                        // retain a fallback copy beyond seven days.
                        cachePolicy: CachePolicy.request,
                        maxStale: _maxCacheAge,
                        keyBuilder: ({
                          required Uri url,
                          Map<String, String>? headers,
                          Object? body,
                        }) {
                          final qp =
                              Map<String, String>.from(url.queryParameters);
                          qp.remove('api_key');
                          final sanitized = url.replace(queryParameters: qp);
                          return sha1
                              .convert(utf8.encode(sanitized.toString()))
                              .toString();
                        },
                      ),
                      evictErrorTileStrategy:
                          EvictErrorTileStrategy.notVisibleRespectMargin,
                      errorTileCallback: (tile, error, stackTrace) {
                        if (!mounted) return;
                        setState(() => _tileErrorCount++);
                      },
                    ),
                    PolylineLayer(
                      polylines: _createCurvedLines(points),
                    ),
                    MarkerLayer(
                      markers: points
                          .map((point) => Marker(
                                point: point,
                                width: 30,
                                height: 30,
                                child: const Icon(
                                  Icons.location_on,
                                  color: Colors.red,
                                  size: 30,
                                ),
                                alignment: const Alignment(0.0, -0.8),
                              ))
                          .toList(),
                    ),
                    RichAttributionWidget(
                      showFlutterMapAttribution: false,
                      attributions: [
                        TextSourceAttribution(
                          'Stadia Maps',
                          onTap: () => launchUrl(
                            Uri.parse('https://stadiamaps.com/'),
                          ),
                        ),
                        TextSourceAttribution(
                          'OpenMapTiles',
                          onTap: () => launchUrl(
                            Uri.parse('https://openmaptiles.org/'),
                          ),
                        ),
                        TextSourceAttribution(
                          'OpenStreetMap',
                          onTap: () => launchUrl(
                            Uri.parse(
                                'https://www.openstreetmap.org/copyright'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_tileErrorCount >= 6)
                  Positioned.fill(
                    child: Container(
                      color: Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: 0.92),
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.map_outlined, size: 28),
                              const SizedBox(height: 8),
                              Text(
                                'Map temporarily unavailable',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Please check your connection and try again.',
                                style: Theme.of(context).textTheme.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton(
                                onPressed: () {
                                  setState(() {
                                    _tileErrorCount = 0;
                                    _reloadToken++;
                                  });
                                },
                                child: const Text('Try again'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<List<LatLng>> _getAirportCoordinates() async {
    List<LatLng> coordinates = [];

    void addCoordinate(Map<String, dynamic>? airport) {
      if (airport != null &&
          airport['latitude'] != null &&
          airport['longitude'] != null) {
        coordinates.add(LatLng(airport['latitude'], airport['longitude']));
      }
    }

    addCoordinate(widget.contributorData['departureAirport']);

    // Check for layovers and add them
    int numberOfLayovers = widget.contributorData['numberOfLayovers'] ?? 0;
    if (numberOfLayovers > 0) {
      addCoordinate(widget.contributorData['firstLayoverAirport']);
      if (numberOfLayovers > 1) {
        addCoordinate(widget.contributorData['secondLayoverAirport']);
      }
    }

    addCoordinate(widget.contributorData['arrivalAirport']);

    return coordinates
        .where((coord) => coord.latitude != 0 && coord.longitude != 0)
        .toList();
  }

  List<Polyline> _createCurvedLines(List<LatLng> points) {
    List<Polyline> polylines = [];
    for (int i = 0; i < points.length - 1; i++) {
      polylines.add(
        Polyline(
          points: _generateCurvedPath([points[i], points[i + 1]]),
          strokeWidth: 3,
          color: Colors.blue,
        ),
      );
    }
    return polylines;
  }

  List<LatLng> _generateCurvedPath(List<LatLng> points) {
    if (points.length < 2) return points;

    LatLng start = points[0];
    LatLng end = points[1];

    double distance = _calculateDistance(start, end);
    double curveHeight = distance * 0.0007;

    LatLng controlPoint = _intermediatePoint(start, end, 0.5, curveHeight);

    List<LatLng> curvedPath = [];
    int numPoints = 100;
    for (int j = 0; j <= numPoints; j++) {
      double t = j / numPoints;
      LatLng point = _quadraticBezier(start, controlPoint, end, t);
      curvedPath.add(point);
    }

    return curvedPath;
  }

  LatLng _intermediatePoint(
      LatLng start, LatLng end, double fraction, double distance) {
    double lat = _interpolate(start.latitude, end.latitude, fraction);
    double lng = _interpolate(start.longitude, end.longitude, fraction);

    lat += distance.abs();

    return LatLng(lat, lng);
  }

  LatLng _quadraticBezier(LatLng p0, LatLng p1, LatLng p2, double t) {
    double lat = (1 - t) * (1 - t) * p0.latitude +
        2 * (1 - t) * t * p1.latitude +
        t * t * p2.latitude;
    double lng = (1 - t) * (1 - t) * p0.longitude +
        2 * (1 - t) * t * p1.longitude +
        t * t * p2.longitude;
    return LatLng(lat, lng);
  }

  double _calculateDistance(LatLng p1, LatLng p2) {
    var p = 0.017453292519943295;
    var c = math.cos;
    var a = 0.5 -
        c((p2.latitude - p1.latitude) * p) / 2 +
        c(p1.latitude * p) *
            c(p2.latitude * p) *
            (1 - c((p2.longitude - p1.longitude) * p)) /
            2;
    return 12742 * math.asin(math.sqrt(a));
  }

  double _interpolate(double start, double end, double fraction) {
    return start + (end - start) * fraction;
  }
}
