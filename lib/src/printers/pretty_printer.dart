import 'dart:convert';

import 'package:logger/logger.dart';
import 'package:logger/src/ansi_color.dart';
import 'package:logger/src/log_printer.dart';
import 'package:logger/src/logger.dart';
import 'package:logger/src/platform/platform.dart';

/// Default implementation of [LogPrinter].
///
/// Output looks like this:
/// ```
/// ┌──────────────────────────
/// │ Error info
/// ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
/// │ Method stack history
/// ├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
/// │ Log message
/// └──────────────────────────
/// ```
class PrettyPrinter extends LogPrinterWithName {
  static const topLeftCorner = '┌';
  static const bottomLeftCorner = '└';
  static const middleCorner = '├';
  static const verticalLine = '│';
  static const doubleDivider = '─';
  static const singleDivider = '┄';

  static final levelColors = {
    Level.verbose: AnsiColor.fg(AnsiColor.grey(0.5)),
    Level.debug: AnsiColor.none(),
    Level.info: AnsiColor.fg(12),
    Level.warning: AnsiColor.fg(208),
    Level.error: AnsiColor.fg(196),
    Level.wtf: AnsiColor.fg(199),
  };

  static final levelEmojis = {
    Level.verbose: '',
    Level.debug: '🐛 ',
    Level.info: '💡 ',
    Level.warning: '⚠️ ',
    Level.error: '⛔ ',
    Level.wtf: '👾 ',
  };

  /// Matches a stacktrace line as generated on Android/iOS devices.
  /// For example:
  /// #1      Logger.log (package:logger/src/logger.dart:115:29)
  static final _deviceStackTraceRegex =
      RegExp(r'#[0-9]+[\s]+.+ \(package:([^\s]+)\)');

  /// Matches a stacktrace line as generated by Flutter web.
  /// For example:
  /// packages/logger/src/printers/pretty_printer.dart 91:37
  static final _webStackTraceRegex =
      RegExp(r'^(?:packages|dart-sdk)\/([^\s]+)');

  static final _browserStackTraceRegex =
      RegExp(r'^(?:package:)?(dart:[^\s]+|[^\s]+)');

  static DateTime _startTime;

  /// Name of this printer.
  ///
  /// If not empty prints the name in the 1st line for each log event.
  /// If [printTime] is [true] will print the time in the 1st line too.
  @override
  final String name;
  /// Amount of [StackTrace] lines to show with message (non-error log).
  final int methodCount;
  /// Amount of error [StackTrace] lines to show with message.
  final int errorMethodCount;
  /// Columns length to format log.
  final int lineLength;
  /// If [true] uses colors for logging.
  final bool colors;
  /// If [true] uses emojis to identify logging types.
  final bool printEmojis;
  /// If [true] shows a line with log event time.
  final bool printTime;

  String _topBorder = '';
  String _middleBorder = '';
  String _bottomBorder = '';

  PrettyPrinter({
    String name,
    int methodCount,
    int errorMethodCount,
    int lineLength,
    bool colors,
    bool printEmojis,
    this.printTime = false,
  })  : name = (name ?? '').trim(),
        methodCount = methodCount ?? LogPlatform.DEFAULT_METHOD_COUNT,
        errorMethodCount =
            errorMethodCount ?? LogPlatform.DEFAULT_ERROR_METHOD_COUNT,
        lineLength = lineLength ?? LogPlatform.DEFAULT_LINE_LENGTH,
        colors = colors ?? LogPlatform.DEFAULT_USE_COLORS,
        printEmojis = printEmojis ?? LogPlatform.DEFAULT_USE_EMOJI {
    _startTime ??= DateTime.now();

    var doubleDividerLine = StringBuffer();
    var singleDividerLine = StringBuffer();
    for (var i = 0; i < this.lineLength - 1; i++) {
      doubleDividerLine.write(doubleDivider);
      singleDividerLine.write(singleDivider);
    }

    _topBorder = '$topLeftCorner$doubleDividerLine';
    _middleBorder = '$middleCorner$singleDividerLine';
    _bottomBorder = '$bottomLeftCorner$doubleDividerLine';
  }

  /// Copies this instance.
  ///
  /// [withName] If present will overwrite [name].
  @override
  PrettyPrinter copy({String withName}) {
    if (withName == null || withName.isEmpty) {
      withName = name;
    }
    var cp = PrettyPrinter(
        name: withName,
        methodCount: methodCount,
        errorMethodCount: errorMethodCount,
        lineLength: lineLength,
        colors: colors,
        printEmojis: printEmojis,
        printTime: printTime);

    cp._ignoredPackages.addAll( _ignoredPackages ) ;
    cp._ignoredPackagesByLevel.addAll( _ignoredPackagesByLevel ) ;

    return cp;
  }

  @override
  List<String> log(LogEvent event) {
    var messageStr = stringifyMessage(event.message);

    String stackTraceStr;
    if (event.stackTrace == null) {
      if (methodCount > 0) {
        // Pass offset 3, since there's always at least 3 lines of logger calls.
        stackTraceStr = formatStackTrace(StackTrace.current, methodCount,
            level: event.level, offset: 3);
      }
    } else if (errorMethodCount > 0) {
      stackTraceStr = formatStackTrace(event.stackTrace, errorMethodCount,
          level: event.level);
    }

    var errorStr = event.error?.toString();

    String timeStr;
    if (printTime) {
      timeStr = getTime();
    }

    return _formatAndPrint(
      event.level,
      messageStr,
      timeStr,
      errorStr,
      stackTraceStr,
    );
  }

  String formatStackTrace(StackTrace stackTrace, int methodCount,
      {Level level, int offset = 0}) {
    var lines = stackTrace.toString().split('\n');

    var formatted = <String>[];
    var count = 0;

    var length = lines.length;
    for (var i = offset; i < length; i++) {
      var line = lines[i].trim();
      if (line.isEmpty) continue;

      if (_discardDeviceStacktraceLine(line, level) ||
          _discardWebStacktraceLine(line, level) ||
          _discardBrowserStacktraceLine(line, level)) {
        continue;
      }
      formatted.add('#$count   ${line.replaceFirst(RegExp(r'#\d+\s+'), '')}');
      if (++count == methodCount) {
        break;
      }
    }

    if (formatted.isEmpty) {
      return null;
    } else {
      return formatted.join('\n');
    }
  }

  final Map<Level, Set<String>> _ignoredPackagesByLevel = {} ;
  final Set<String> _ignoredPackages = {} ;

  /// Returns a list of ignored packages.
  List<String> get ignoredPackages {
    var l1 = _ignoredPackagesByLevel.values.expand((e) => e) ;
    var set = Set.from( l1 ) ;
    set.addAll( _ignoredPackages ) ;
    return List.from(set) ;
  }

  /// Clears the ignored packages.
  void clearIgnoredPackages() {
    _ignoredPackagesByLevel.clear();
    _ignoredPackages.clear() ;
  }

  /// Ignores a [package].
  ///
  /// [level] If provided will ignored only for this [Level].
  void ignorePackage(String package, [Level level]) {
    if (package == null) return ;
    package = package.trim() ;
    if (package.isEmpty) return ;

    if (level == null) {
      _ignoredPackages.add(package) ;
    }
    else {
      var set = _ignoredPackagesByLevel.putIfAbsent(level, () => {}) ;
      set.add(package) ;
    }
  }

  /// Removes a [package] from ignore list.
  ///
  /// [level] If provided will remove it only if defined for this [Level].
  bool doNotIgnorePackage(String package, [Level level]) {
    if (package == null) return false;
    package = package.trim() ;

    if (level != null) {
      var set = _ignoredPackagesByLevel[level] ;
      return set.remove(package) ;
    }
    else {
      var rm = _ignoredPackages.remove(package) ;
      for (var set in _ignoredPackagesByLevel.values) {
        if ( set.remove(package) ) {
          rm = true ;
        }
      }
      return rm ;
    }

  }

  bool _isIgnoredPackage(String package, Level level) {
    if (package == null || package.isEmpty) return false;
    if (package.startsWith('logger/') ||
        package.startsWith('dart-sdk/lib') ||
        package.startsWith('dart:')) return true;

    for (var pkg in _ignoredPackages) {
      if (package.startsWith('$pkg/')) return true;
    }

    if (level != null) {
      var levelIgnoredPackages = _ignoredPackagesByLevel[level];
      if (levelIgnoredPackages != null) {
        for (var pkg in levelIgnoredPackages) {
          if (package.startsWith('$pkg/')) return true;
        }
      }
    }

    return false;
  }

  bool _discardDeviceStacktraceLine(String line, Level level) {
    var match = _deviceStackTraceRegex.matchAsPrefix(line);
    if (match == null) {
      return false;
    }
    var package = match.group(1);
    return _isIgnoredPackage(package, level) ;
  }

  bool _discardWebStacktraceLine(String line, Level level) {
    var match = _webStackTraceRegex.matchAsPrefix(line);
    if (match == null) {
      return false;
    }
    var package = match.group(1) ;
    return _isIgnoredPackage(package, level) ;
  }

  bool _discardBrowserStacktraceLine(String line, Level level) {
    var match = _browserStackTraceRegex.matchAsPrefix(line);
    if (match == null) {
      return false;
    }
    var package = match.group(1);
    return _isIgnoredPackage(package, level) ;
  }

  String getTime() {
    String _threeDigits(int n) {
      if (n >= 100) return '$n';
      if (n >= 10) return '0$n';
      return '00$n';
    }

    String _twoDigits(int n) {
      if (n >= 10) return '$n';
      return '0$n';
    }

    var now = DateTime.now();
    var h = _twoDigits(now.hour);
    var min = _twoDigits(now.minute);
    var sec = _twoDigits(now.second);
    var ms = _threeDigits(now.millisecond);
    var timeSinceStart = now.difference(_startTime).toString();
    return '$h:$min:$sec.$ms (+$timeSinceStart)';
  }

  String stringifyMessage(dynamic message) {
    if (message is Map || message is Iterable) {
      var encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(message);
    } else {
      return message.toString();
    }
  }

  AnsiColor _getLevelColor(Level level) {
    if (colors) {
      return levelColors[level];
    } else {
      return AnsiColor.none();
    }
  }

  AnsiColor _getErrorColor(Level level) {
    if (colors) {
      if (level == Level.wtf) {
        return levelColors[Level.wtf].toBg();
      } else {
        return levelColors[Level.error].toBg();
      }
    } else {
      return AnsiColor.none();
    }
  }

  String _getEmoji(Level level) {
    if (printEmojis) {
      return levelEmojis[level];
    } else {
      return '';
    }
  }

  List<String> _formatAndPrint(
    Level level,
    String message,
    String time,
    String error,
    String stacktrace,
  ) {
    // This code is non trivial and a type annotation here helps understanding.
    // ignore: omit_local_variable_types
    List<String> buffer = [];
    var color = _getLevelColor(level);
    buffer.add(color(_topBorder));

    var addedTime = false ;
    if (name.isNotEmpty) {
      var line = '$name $verticalLine ${ getLevelName(level) }' ;

      if (time != null) {
        line += ' $verticalLine $time' ;
        addedTime = true ;
      }

      buffer..add(color('$verticalLine $line'))..add(color(_middleBorder));
    }

    if (error != null) {
      var errorColor = _getErrorColor(level);
      for (var line in error.split('\n')) {
        buffer.add(
          color('$verticalLine ') +
              errorColor.resetForeground +
              errorColor(line) +
              errorColor.resetBackground,
        );
      }
      buffer.add(color(_middleBorder));
    }

    if (stacktrace != null) {
      for (var line in stacktrace.split('\n')) {
        buffer.add('$color$verticalLine $line');
      }
      buffer.add(color(_middleBorder));
    }

    if (time != null && !addedTime) {
      buffer..add(color('$verticalLine $time'))..add(color(_middleBorder));
    }

    var emoji = _getEmoji(level);
    for (var line in message.split('\n')) {
      buffer.add(color('$verticalLine $emoji$line'));
    }
    buffer.add(color(_bottomBorder));

    return buffer;
  }
}
