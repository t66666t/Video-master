typedef MonotonicMicroseconds = int Function();

/// A single, monotonic media timeline for frame-driven UI.
///
/// Playback-rate changes preserve the exact current media position and only
/// change its slope. Native player samples are not blended into this clock;
/// callers may explicitly reset it for seeks or real discontinuities.
class PlaybackTimelineClock {
  PlaybackTimelineClock({MonotonicMicroseconds? nowMicroseconds})
    : _nowMicroseconds = nowMicroseconds ?? _defaultNowMicroseconds;

  static final Stopwatch _stopwatch = Stopwatch()..start();

  static int _defaultNowMicroseconds() => _stopwatch.elapsedMicroseconds;

  final MonotonicMicroseconds _nowMicroseconds;
  Duration _anchorPosition = Duration.zero;
  int _anchorTimeUs = 0;
  Duration _duration = Duration.zero;
  double _rate = 1.0;
  double _driftCorrection = 0.0;
  bool _running = false;
  bool _initialized = false;
  bool _frameDriven = false;
  int? _lastFrameTimestampUs;
  int _lastFrameIntervalUs = 16667;
  int _ignoredNativeSamples = 0;
  int _driftConfirmationSamples = 0;
  int _lastDriftSign = 0;

  bool get isInitialized => _initialized;
  bool get isRunning => _running;
  double get rate => _rate;
  double get effectiveRate => _rate * (1 + _driftCorrection);

  Duration get position {
    // Once the display pipeline starts sampling this clock, the last sampled
    // position is the only position which has actually been presented. Do not
    // mix callback execution time into it: scheduler jitter would otherwise
    // become visible as horizontal danmaku jitter.
    if (_frameDriven) return _clamp(_anchorPosition);
    if (!_initialized || !_running) return _clamp(_anchorPosition);
    final elapsedUs = (_nowMicroseconds() - _anchorTimeUs).clamp(0, 1 << 62);
    return _clamp(
      _anchorPosition +
          Duration(microseconds: (elapsedUs * effectiveRate).round()),
    );
  }

  /// Advances the media clock using Flutter's VSync timestamp.
  ///
  /// Consecutive frame timestamps describe presentation time, unlike the wall
  /// time at which a Dart callback happened to execute. A missed frame advances
  /// by the complete missed interval, so the next presented position remains
  /// time-linear and no delayed catch-up is introduced.
  Duration sampleFrame(Duration frameTimestamp) {
    final timestampUs = frameTimestamp.inMicroseconds;
    _frameDriven = true;
    if (!_initialized) {
      _anchorTimeUs = _nowMicroseconds();
      _initialized = true;
    }

    final previousTimestampUs = _lastFrameTimestampUs;
    _lastFrameTimestampUs = timestampUs;
    if (!_running || previousTimestampUs == null) {
      return _clamp(_anchorPosition);
    }

    final elapsedUs = timestampUs - previousTimestampUs;
    if (elapsedUs <= 0) return _clamp(_anchorPosition);
    _lastFrameIntervalUs = elapsedUs.clamp(5000, 50000);
    _anchorPosition = _clamp(
      _anchorPosition +
          Duration(microseconds: (elapsedUs * effectiveRate).round()),
    );
    return _anchorPosition;
  }

  /// Observes a native media position without ever moving the presented
  /// position directly. Small, sustained drift is removed by changing the
  /// slope by at most 0.5%; coarse video-frame samples and transient samples
  /// around play/rate transitions therefore cannot make overlays jump.
  void observeNativePosition(Duration nativePosition) {
    if (!_initialized || !_running || !_frameDriven) return;
    if (_ignoredNativeSamples > 0) {
      _ignoredNativeSamples--;
      return;
    }

    final errorUs =
        nativePosition.inMicroseconds - _anchorPosition.inMicroseconds;
    final deadBandUs = _maxInt(_lastFrameIntervalUs, 8333);
    final absoluteErrorUs = errorUs.abs();
    if (absoluteErrorUs <= deadBandUs) {
      _driftConfirmationSamples = 0;
      _lastDriftSign = 0;
      _driftCorrection *= 0.75;
      if (_driftCorrection.abs() < 0.00001) _driftCorrection = 0;
      return;
    }

    // A large mismatch is a seek/discontinuity candidate. Callers reset the
    // clock only after the seek itself is confirmed; treating it as drift here
    // would create a visible speed surge.
    if (absoluteErrorUs > 100000) {
      _driftConfirmationSamples = 0;
      _lastDriftSign = 0;
      return;
    }

    final sign = errorUs.sign.toInt();
    if (sign != _lastDriftSign) {
      _lastDriftSign = sign;
      _driftConfirmationSamples = 1;
      return;
    }
    _driftConfirmationSamples++;
    if (_driftConfirmationSamples < 3) return;

    final nominalRate = _rate <= 0 ? 1.0 : _rate;
    final targetRelativeCorrection = (errorUs / (2000000 * nominalRate)).clamp(
      -0.005,
      0.005,
    );
    _driftCorrection =
        _driftCorrection * 0.75 + targetRelativeCorrection * 0.25;
  }

  void reset(
    Duration position, {
    required bool running,
    required double rate,
    Duration? duration,
  }) {
    if (duration != null) _duration = duration;
    _rate = _validRate(rate);
    _driftCorrection = 0;
    _anchorPosition = _clamp(position);
    _anchorTimeUs = _nowMicroseconds();
    _running = running;
    _initialized = true;
    _frameDriven = false;
    _lastFrameTimestampUs = null;
    _lastFrameIntervalUs = 16667;
    _ignoredNativeSamples = 4;
    _driftConfirmationSamples = 0;
    _lastDriftSign = 0;
  }

  void setRate(double rate) {
    final nextRate = _validRate(rate);
    if ((_rate - nextRate).abs() < 0.0001) return;
    final current = position;
    _anchorPosition = current;
    _anchorTimeUs = _nowMicroseconds();
    _rate = nextRate;
    _driftCorrection = 0;
    _ignoredNativeSamples = 4;
    _driftConfirmationSamples = 0;
    _lastDriftSign = 0;
    _initialized = true;
  }

  void setRunning(bool running, {Duration? position}) {
    if (_running == running && position == null) return;
    _anchorPosition = _clamp(position ?? this.position);
    _anchorTimeUs = _nowMicroseconds();
    _running = running;
    _driftCorrection = 0;
    _ignoredNativeSamples = running ? 4 : 0;
    _driftConfirmationSamples = 0;
    _lastDriftSign = 0;
    _initialized = true;
    // The next VSync becomes the new presentation-time baseline. This keeps a
    // paused interval out of the first frame after resume without moving the
    // last position that was actually drawn.
    _lastFrameTimestampUs = null;
  }

  void setDuration(Duration duration) {
    _duration = duration < Duration.zero ? Duration.zero : duration;
    _anchorPosition = _clamp(_anchorPosition);
  }

  double _validRate(double value) {
    return value.isFinite && value > 0 ? value : 1.0;
  }

  Duration _clamp(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (_duration > Duration.zero && value > _duration) return _duration;
    return value;
  }
}

int _maxInt(int left, int right) => left > right ? left : right;
