import '../models/subtitle_model.dart';

class SubtitleParser {
  /// 自动解析字幕内容 (根据内容特征)
  static List<SubtitleItem> parse(String content) {
    if (content.startsWith('WEBVTT') || content.contains('WEBVTT')) {
      return parseVtt(content);
    } else if (content.contains('[Script Info]') || content.contains('[Events]')) {
      return parseAss(content);
    } else if (content.contains('-->')) {
      return parseSrt(content);
    } else if (RegExp(r'\[\d{2}:\d{2}').hasMatch(content)) {
      return parseLrc(content);
    }
    return []; // 未知格式
  }

  /// 解析 WebVTT 格式
  static List<SubtitleItem> parseVtt(String vttContent) {
    List<SubtitleItem> subtitles = [];
    final String content = vttContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');
    
    int index = 0;
    while (index < lines.length) {
      String line = lines[index].trim();
      // Skip header or empty lines
      if (line.isEmpty || line == 'WEBVTT') {
        index++;
        continue;
      }
      
      // VTT might have an ID line before the timestamp
      // Check if current line is timestamp or next line is timestamp
      String? timestampLine;
      
      if (line.contains('-->')) {
        timestampLine = line;
      } else if (index + 1 < lines.length && lines[index + 1].contains('-->')) {
        index++; // Skip ID line
        timestampLine = lines[index].trim();
      }
      
      if (timestampLine != null && timestampLine.contains('-->')) {
        var parts = timestampLine.split('-->');
        if (parts.length == 2) {
          Duration start = _parseVttDuration(parts[0].trim());
          Duration end = _parseVttDuration(parts[1].trim());
          
          index++;
          StringBuffer textBuffer = StringBuffer();
          while (index < lines.length) {
            String textLine = lines[index].trim();
            if (textLine.isEmpty) break;
            if (textBuffer.isNotEmpty) textBuffer.write('\n');
            textBuffer.write(textLine);
            index++;
          }
          
          subtitles.add(SubtitleItem(
            index: subtitles.length + 1,
            startTime: start,
            endTime: end,
            text: textBuffer.toString(),
          ));
        } else {
          index++;
        }
      } else {
        index++;
      }
    }
    return subtitles;
  }

  /// 解析 ASS/SSA 格式
  static List<SubtitleItem> parseAss(String assContent) {
    List<SubtitleItem> subtitles = [];
    final String content = assContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');
    
    bool inEvents = false;
    List<String> format = [];
    int startIndex = -1;
    int endIndex = -1;
    int textIndex = -1;
    
    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;
      
      if (line.startsWith('[Events]')) {
        inEvents = true;
        continue;
      }
      
      if (!inEvents) continue;
      
      if (line.startsWith('Format:')) {
        final formatStr = line.substring(7).trim();
        format = formatStr.split(',').map((e) => e.trim().toLowerCase()).toList();
        startIndex = format.indexOf('start');
        endIndex = format.indexOf('end');
        textIndex = format.indexOf('text');
        continue;
      }
      
      if (line.startsWith('Dialogue:')) {
        if (startIndex == -1 || endIndex == -1 || textIndex == -1) {
          // Fallback if no format line found (assume standard)
          // Standard: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
          // But safer to rely on Format line. If missing, maybe try default indices?
          // Let's assume standard ASS:
          // Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
          // Indices: 1, 2, 9
          startIndex = 1;
          endIndex = 2;
          textIndex = 9;
        }
        
        // Dialogue: lines are comma separated, BUT the text part can contain commas.
        // We need to split by comma ONLY up to the text field.
        
        final rawParts = line.substring(9).trim(); // Remove "Dialogue:"
        // We split by comma, but limit the number of splits to ensure Text is the last chunk?
        // No, Text is usually the last field, but technically could be anywhere defined by Format.
        // Usually Text is last.
        
        // If Text is the last field (which is standard), we can split with limit.
        // Format length tells us how many fields.
        
        int formatLen = format.isNotEmpty ? format.length : 10;
        List<String> parts = [];
        
        // We need to split manually to handle the "Text can contain commas" issue
        // The standard says: "The last field is always the text field, so it can contain commas."
        // So we split formatLen - 1 times.
        
        // Simple approach: Split by comma formatLen-1 times.
        // Dart's split doesn't support limit like "split first N".
        // We can loop.
        
        String remaining = rawParts;
        for (int i = 0; i < formatLen - 1; i++) {
          int commaIndex = remaining.indexOf(',');
          if (commaIndex == -1) break;
          parts.add(remaining.substring(0, commaIndex));
          remaining = remaining.substring(commaIndex + 1);
        }
        parts.add(remaining); // The rest is the last field (Text)
        
        if (parts.length >= 3) { // At least Start, End, Text
             // Use detected indices, mapped to our parts list.
             // Note: Format indices are 0-based.
             
             if (startIndex < parts.length && endIndex < parts.length && textIndex < parts.length) {
               try {
                 Duration start = _parseAssDuration(parts[startIndex].trim());
                 Duration end = _parseAssDuration(parts[endIndex].trim());
                 String text = parts[textIndex];
                 
                 // Remove ASS tags like {\pos(400,570)} or {\c&HFFFFFF&}
                 text = text.replaceAll(RegExp(r'\{.*?\}'), '');
                 text = text.replaceAll(r'\N', '\n').replaceAll(r'\n', '\n');
                 
                 subtitles.add(SubtitleItem(
                   index: subtitles.length + 1,
                   startTime: start,
                   endTime: end,
                   text: text,
                 ));
               } catch (e) {
                 // ignore parse error
               }
             }
        }
      }
    }
    return subtitles..sort((a, b) => a.startTime.compareTo(b.startTime));
  }

  /// 解析 SRT 格式
  static List<SubtitleItem> parseSrt(String srtContent) {
    List<SubtitleItem> subtitles = [];
    final String content = srtContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');
    
    int index = 0;
    while (index < lines.length) {
      String line = lines[index].trim();
      if (line.isEmpty) {
        index++;
        continue;
      }
      
      int? seqNum = int.tryParse(line);
      if (seqNum != null) {
        index++;
        if (index >= lines.length) break;
        line = lines[index].trim();
      }
      
      if (line.contains('-->')) {
        var parts = line.split('-->');
        if (parts.length == 2) {
          Duration start = _parseSrtDuration(parts[0].trim());
          Duration end = _parseSrtDuration(parts[1].trim());
          
          index++;
          StringBuffer textBuffer = StringBuffer();
          while (index < lines.length) {
            String textLine = lines[index].trim();
            if (textLine.isEmpty) break;
            if (textBuffer.isNotEmpty) textBuffer.write('\n');
            textBuffer.write(textLine);
            index++;
          }
          
          subtitles.add(SubtitleItem(
            index: subtitles.length + 1,
            startTime: start,
            endTime: end,
            text: textBuffer.toString(),
          ));
        } else {
          index++;
        }
      } else {
        index++;
      }
    }
    return subtitles;
  }

  /// 解析 LRC 格式
  /// 格式: [mm:ss.xx]歌词内容
  static List<SubtitleItem> parseLrc(String lrcContent) {
    List<SubtitleItem> subtitles = [];
    final String content = lrcContent.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<String> lines = content.split('\n');
    
    // 正则匹配时间标签 [mm:ss.xx] 或 [mm:ss]
    // 支持一行有多个时间标签的情况，如 [00:12.00][00:24.00]重复歌词
    final RegExp timeTagRegExp = RegExp(r'\[(\d{2}):(\d{2})(\.(\d{2,3}))?\]');

    List<_LrcTempItem> tempItems = [];

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      // 提取所有时间标签
      final matches = timeTagRegExp.allMatches(line);
      if (matches.isEmpty) continue;

      // 提取歌词文本 (去掉时间标签剩下的部分)
      String text = line.replaceAll(timeTagRegExp, '').trim();
      if (text.isEmpty) continue; // 跳过只有时间没歌词的行

      for (var match in matches) {
        int minutes = int.parse(match.group(1)!);
        int seconds = int.parse(match.group(2)!);
        int milliseconds = 0;
        if (match.group(4) != null) {
          String msStr = match.group(4)!;
          // LRC 的毫秒通常是 2位 (10ms单位) 或 3位 (1ms单位)
          if (msStr.length == 2) {
            milliseconds = int.parse(msStr) * 10;
          } else {
            milliseconds = int.parse(msStr);
          }
        }

        Duration startTime = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds,
        );

        tempItems.add(_LrcTempItem(startTime, text));
      }
    }

    // 按时间排序
    tempItems.sort((a, b) => a.startTime.compareTo(b.startTime));

    // 生成最终的 SubtitleItem (推断 endTime)
    for (int i = 0; i < tempItems.length; i++) {
      final current = tempItems[i];
      Duration endTime;
      
      if (i < tempItems.length - 1) {
        // 结束时间 = 下一句的开始时间
        endTime = tempItems[i + 1].startTime;
      } else {
        // 最后一句，默认显示 3 秒
        endTime = current.startTime + const Duration(seconds: 3);
      }

      subtitles.add(SubtitleItem(
        index: i + 1,
        startTime: current.startTime,
        endTime: endTime,
        text: current.text,
      ));
    }

    return subtitles;
  }

  static Duration _parseSrtDuration(String timestamp) {
    try {
      var parts = timestamp.split(',');
      var timeParts = parts[0].split(':');
      
      int hours = int.parse(timeParts[0]);
      int minutes = int.parse(timeParts[1]);
      int seconds = int.parse(timeParts[2]);
      int milliseconds = parts.length > 1 ? int.parse(parts[1]) : 0;
      
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds,
      );
    } catch (e) {
      return Duration.zero;
    }
  }

  static Duration _parseVttDuration(String timestamp) {
    try {
      var parts = timestamp.split('.');
      var timeParts = parts[0].split(':');
      
      int hours = 0;
      int minutes = 0;
      int seconds = 0;

      if (timeParts.length == 3) {
        hours = int.parse(timeParts[0]);
        minutes = int.parse(timeParts[1]);
        seconds = int.parse(timeParts[2]);
      } else if (timeParts.length == 2) {
        minutes = int.parse(timeParts[0]);
        seconds = int.parse(timeParts[1]);
      }
      
      int milliseconds = parts.length > 1 ? int.parse(parts[1]) : 0;
      
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: milliseconds,
      );
    } catch (e) {
      return Duration.zero;
    }
  }

  static Duration _parseAssDuration(String timestamp) {
    try {
      // Format: h:mm:ss.cs (centiseconds)
      var parts = timestamp.split('.');
      var timeParts = parts[0].split(':');
      
      int hours = int.parse(timeParts[0]);
      int minutes = int.parse(timeParts[1]);
      int seconds = int.parse(timeParts[2]);
      int centiseconds = parts.length > 1 ? int.parse(parts[1]) : 0;
      
      return Duration(
        hours: hours,
        minutes: minutes,
        seconds: seconds,
        milliseconds: centiseconds * 10,
      );
    } catch (e) {
      return Duration.zero;
    }
  }
}

class _LrcTempItem {
  final Duration startTime;
  final String text;
  _LrcTempItem(this.startTime, this.text);
}
