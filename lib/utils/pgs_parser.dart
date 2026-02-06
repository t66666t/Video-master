import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/subtitle_model.dart';

class PgsRenderParams {
  final PgsPcs pcs;
  final PgsPds pds;
  final PgsOds ods;

  PgsRenderParams(this.pcs, this.pds, this.ods);
}

class PgsParser {
  static Future<List<SubtitleItem>> parse(String path) async {
    final file = File(path);
    if (!await file.exists()) return [];

    final bytes = await file.readAsBytes();
    final data = ByteData.sublistView(bytes);
    int offset = 0;

    List<SubtitleItem> subtitles = [];
    
    PgsPcs? currentPcs;
    PgsPds? lastPds;
    final Map<int, PgsPds> paletteById = <int, PgsPds>{};
    final Map<int, PgsOds> objectById = <int, PgsOds>{};
    final Map<int, _PgsOdsAccumulator> odsAccumulators = <int, _PgsOdsAccumulator>{};
    
    // We need to keep track of the active palette and objects across segments if needed
    // But typically in a simple parser we process Display Sets.
    // A Display Set ends with an END segment (0x80).
    
    while (offset < data.lengthInBytes) {
      if (offset + 13 > data.lengthInBytes) break; // Header is 13 bytes

      // PG header
      // 0-1: Magic 'PG' (0x50, 0x47)
      // 2-5: PTS (Presentation Time Stamp) - 90kHz
      // 6-9: DTS (Decoding Time Stamp) - 0 (often)
      // 10: Segment Type
      // 11-12: Segment Length
      
      final magic = data.getUint16(offset);
      if (magic != 0x5047) {
        // Scan forward to find next PG
        offset++;
        continue;
      }

      final pts = data.getUint32(offset + 2);
      // Skip DTS (4 bytes)
      final type = data.getUint8(offset + 10);
      final length = data.getUint16(offset + 11);
      
      final segmentDataOffset = offset + 13;
      final nextSegmentOffset = segmentDataOffset + length;
      
      if (nextSegmentOffset > data.lengthInBytes) break;

      final segmentBytes = bytes.sublist(segmentDataOffset, nextSegmentOffset);
      final segmentByteData = ByteData.sublistView(segmentBytes);

      // Process Segment
      switch (type) {
        case 0x14: // PDS - Palette Definition Segment
          final pds = PgsPds.parse(segmentByteData);
          paletteById[pds.id] = pds;
          lastPds = pds;
          break;
        case 0x15: // ODS - Object Definition Segment
          final segment = _parseOdsSegment(segmentByteData);
          if (segment != null) {
            if ((segment.sequenceFlag & 0x80) != 0) {
              odsAccumulators[segment.id] = _PgsOdsAccumulator(
                id: segment.id,
                version: segment.version,
                width: segment.width ?? 0,
                height: segment.height ?? 0,
                dataLength: segment.dataLength,
              );
            }
            final accumulator = odsAccumulators[segment.id];
            if (accumulator != null) {
              accumulator.add(segment.data);
              if ((segment.sequenceFlag & 0x40) != 0) {
                final ods = accumulator.build();
                if (ods != null) {
                  objectById[segment.id] = ods;
                }
                odsAccumulators.remove(segment.id);
              }
            }
          }
          break;
        case 0x16: // PCS - Presentation Composition Segment
          currentPcs = PgsPcs.parse(segmentByteData, pts);
          break;
        case 0x17: // WDS - Window Definition Segment
          // currentWds = PgsWds.parse(segmentByteData);
          break;
        case 0x80: // END - End of Display Set
          if (currentPcs != null) {
            // Create subtitle item
            // We need to capture the current PDS and ODS
            // Note: In real PGS, objects and palettes can be defined in previous sets.
            // But for this simple implementation, we assume they are available or we just use what we have.
            
            // If it's an acquisition point or epoch start, it resets context.
            // If normal, it might use previous.
            
            // For now, let's create a closure that captures current data
            if (currentPcs.state != CompositionState.epochStart && 
                currentPcs.state != CompositionState.acquisitionPoint &&
                currentPcs.state != CompositionState.normal) {
               // Only display if we have content? 
               // Actually PCS defines what is displayed.
            }
            
            // Only if we have an object to show
            if (currentPcs.objects.isNotEmpty) {
              final capturedPcs = currentPcs;
              final obj = capturedPcs.objects.first;
              final capturedOds = objectById[obj.objectId];
              final capturedPds = paletteById[capturedPcs.paletteId] ?? lastPds;
              if (capturedPds != null && capturedOds != null) {
                final startTime = Duration(milliseconds: (capturedPcs.pts / 90).round());
                subtitles.add(SubtitleItem(
                  index: subtitles.length + 1,
                  startTime: startTime,
                  endTime: startTime + const Duration(seconds: 2),
                  imageLoader: () async {
                    return compute(_renderSubtitleCompute, PgsRenderParams(capturedPcs, capturedPds, capturedOds));
                  },
                ));
              }
            } else {
              // PCS with 0 objects -> Clear screen.
              // We can use this to set the endTime of the previous subtitle.
               final clearTime = Duration(milliseconds: (currentPcs.pts / 90).round());
               if (subtitles.isNotEmpty) {
                 final last = subtitles.last;
                 if (last.endTime == last.startTime + const Duration(seconds: 2)) {
                   subtitles[subtitles.length - 1] = SubtitleItem(
                     index: last.index,
                     startTime: last.startTime,
                     endTime: clearTime,
                     text: last.text,
                     imageLoader: last.imageLoader,
                   );
                 }
               }
            }
          }
          
          // Reset per display set? 
          // ODS and PDS might persist across segments in valid PGS stream (Epoch).
          // But usually repeated. We'll keep them for now, but PCS is unique per instant.
          currentPcs = null; 
          break;
      }

      offset = nextSegmentOffset;
    }
    
    // Sort and fix durations
    subtitles.sort((a, b) => a.startTime.compareTo(b.startTime));
    for (int i = 0; i < subtitles.length - 1; i++) {
      if (subtitles[i].endTime > subtitles[i+1].startTime) {
        subtitles[i] = SubtitleItem(
            index: subtitles[i].index,
            startTime: subtitles[i].startTime,
            endTime: subtitles[i+1].startTime,
            text: subtitles[i].text,
            imageLoader: subtitles[i].imageLoader,
        );
      }
    }

    return subtitles;
  }

  static Future<Uint8List?> _renderSubtitleCompute(PgsRenderParams params) async {
    return _renderSubtitle(params.pcs, params.pds, params.ods);
  }

  static _PgsOdsSegment? _parseOdsSegment(ByteData data) {
    if (data.lengthInBytes < 7) return null;
    final id = data.getUint16(0);
    final version = data.getUint8(2);
    final sequenceFlag = data.getUint8(3);
    final dataLength = (data.getUint8(4) << 16) | (data.getUint8(5) << 8) | data.getUint8(6);
    int offset = 7;
    int? width;
    int? height;
    if ((sequenceFlag & 0x80) != 0) {
      if (data.lengthInBytes < 11) return null;
      width = data.getUint16(7);
      height = data.getUint16(9);
      offset = 11;
    }
    if (offset > data.lengthInBytes) return null;
    final part = data.buffer.asUint8List(data.offsetInBytes + offset, data.lengthInBytes - offset);
    return _PgsOdsSegment(
      id: id,
      version: version,
      sequenceFlag: sequenceFlag,
      dataLength: dataLength,
      width: width,
      height: height,
      data: part,
    );
  }

  static Future<Uint8List?> _renderSubtitle(PgsPcs pcs, PgsPds pds, PgsOds ods) async {
    // 1. Decode RLE to indices
    final width = ods.width;
    final height = ods.height;
    final indices = _decodeRle(ods.rleData, width, height);
    
    if (indices.length != width * height) {
      // Decode error or size mismatch
      return null;
    }

    final frameWidth = pcs.width > 0 ? pcs.width : width;
    final frameHeight = pcs.height > 0 ? pcs.height : height;
    final canvas = Uint8List(frameWidth * frameHeight);
    final PgsCompositionObject? obj = pcs.objects.isNotEmpty ? pcs.objects.first : null;
    final offsetX = obj?.x ?? 0;
    final offsetY = obj?.y ?? 0;
    for (int y = 0; y < height; y++) {
      final int destY = y + offsetY;
      if (destY < 0 || destY >= frameHeight) continue;
      final int srcRow = y * width;
      for (int x = 0; x < width; x++) {
        final int destX = x + offsetX;
        if (destX < 0 || destX >= frameWidth) continue;
        final int index = indices[srcRow + x];
        if (index == 0) continue;
        canvas[destY * frameWidth + destX] = index;
      }
    }

    return _createBmp(canvas, frameWidth, frameHeight, pds.palette);
  }
  
  static Uint8List _decodeRle(Uint8List rle, int width, int height) {
    final pixels = Uint8List(width * height);
    int pixelIndex = 0;
    int offset = 0;
    
    while (offset < rle.length && pixelIndex < pixels.length) {
      final b0 = rle[offset++];
      
      if (b0 != 0) {
        pixels[pixelIndex++] = b0;
      } else {
        if (offset >= rle.length) break;
        final b1 = rle[offset++];
        
        if (b1 == 0) {
          // End of line
          // Skip to next line start?
          // Actually in PGS RLE, EOL means fill rest of line with 0? Or just skip?
          // Usually we just ensure we align to width.
          int x = pixelIndex % width;
          if (x != 0) {
             pixelIndex += (width - x);
          }
        } else if ((b1 & 0xC0) == 0) {
          // 00xxxxxx : Run of 0, length x
          int count = b1 & 0x3F;
          if (pixelIndex + count > pixels.length) count = pixels.length - pixelIndex;
          pixelIndex += count; // 0 is default in Uint8List
        } else if ((b1 & 0xC0) == 0x40) {
          // 01xxxxxx LLLLLLLL : Run of 0, length ((x<<8) + L)
          if (offset >= rle.length) break;
          final b2 = rle[offset++];
          int count = ((b1 & 0x3F) << 8) + b2;
          if (pixelIndex + count > pixels.length) count = pixels.length - pixelIndex;
          pixelIndex += count;
        } else if ((b1 & 0xC0) == 0x80) {
          // 10xxxxxx CCCCCCCC : Run of color C, length x
          if (offset >= rle.length) break;
          final color = rle[offset++];
          int count = b1 & 0x3F;
          if (pixelIndex + count > pixels.length) count = pixels.length - pixelIndex;
          pixels.fillRange(pixelIndex, pixelIndex + count, color);
          pixelIndex += count;
        } else if ((b1 & 0xC0) == 0xC0) {
           // 11xxxxxx LLLLLLLL CCCCCCCC : Run of color C, length ((x<<8) + L)
           if (offset + 1 >= rle.length) break;
           final b2 = rle[offset++];
           final color = rle[offset++];
           int count = ((b1 & 0x3F) << 8) + b2;
           if (pixelIndex + count > pixels.length) count = pixels.length - pixelIndex;
           pixels.fillRange(pixelIndex, pixelIndex + count, color);
           pixelIndex += count;
        }
      }
    }
    
    return pixels;
  }

  static Uint8List _createBmp(Uint8List indices, int width, int height, Map<int, int> palette) {
    // Create RGBA buffer (4 bytes per pixel)
    // BMP is usually BGRA for Windows/standard, but we can make generic.
    // Flutter decodes standard BMP.
    // Let's create a 32-bit BGRA BMP.
    
    // Header size: 14 (FileHeader) + 40 (InfoHeader) = 54
    final fileSize = 54 + (width * height * 4);
    final bmp = Uint8List(fileSize);
    final view = ByteData.view(bmp.buffer);
    
    // File Header
    view.setUint16(0, 0x424D, Endian.little); // 'BM'
    view.setUint32(2, fileSize, Endian.little);
    view.setUint32(10, 54, Endian.little); // Offset to pixel data
    
    // Info Header
    view.setUint32(14, 40, Endian.little); // Header size
    view.setInt32(18, width, Endian.little);
    view.setInt32(22, -height, Endian.little); // Negative height for top-down
    view.setUint16(26, 1, Endian.little); // Planes
    view.setUint16(28, 32, Endian.little); // BPP
    view.setUint32(30, 0, Endian.little); // Compression (BI_RGB)
    view.setUint32(34, width * height * 4, Endian.little); // Image size
    
    // Pixels
    int pixelOffset = 54;
    for (int i = 0; i < indices.length; i++) {
      final colorIndex = indices[i];
      final color = palette[colorIndex] ?? 0x00000000; // ARGB
      
      // BMP expects BGRA
      final a = (color >> 24) & 0xFF;
      final r = (color >> 16) & 0xFF;
      final g = (color >> 8) & 0xFF;
      final b = (color) & 0xFF;
      
      bmp[pixelOffset++] = b;
      bmp[pixelOffset++] = g;
      bmp[pixelOffset++] = r;
      bmp[pixelOffset++] = a;
    }
    
    return bmp;
  }
}

class _PgsOdsSegment {
  final int id;
  final int version;
  final int sequenceFlag;
  final int dataLength;
  final int? width;
  final int? height;
  final Uint8List data;

  _PgsOdsSegment({
    required this.id,
    required this.version,
    required this.sequenceFlag,
    required this.dataLength,
    required this.width,
    required this.height,
    required this.data,
  });
}

class _PgsOdsAccumulator {
  final int id;
  final int version;
  final int width;
  final int height;
  final int dataLength;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  _PgsOdsAccumulator({
    required this.id,
    required this.version,
    required this.width,
    required this.height,
    required this.dataLength,
  });

  void add(Uint8List data) {
    _builder.add(data);
  }

  PgsOds? build() {
    if (width <= 0 || height <= 0) return null;
    final bytes = _builder.takeBytes();
    final int size = dataLength > 0 && dataLength <= bytes.length ? dataLength : bytes.length;
    if (size <= 0) return null;
    return PgsOds(
      id: id,
      version: version,
      width: width,
      height: height,
      rleData: Uint8List.fromList(bytes.sublist(0, size)),
    );
  }
}

class PgsPcs {
  final int pts;
  final int width;
  final int height;
  final int frameRate;
  final int compositionNumber;
  final CompositionState state;
  final int paletteId;
  final List<PgsCompositionObject> objects;

  PgsPcs({
    required this.pts,
    required this.width,
    required this.height,
    required this.frameRate,
    required this.compositionNumber,
    required this.state,
    required this.paletteId,
    required this.objects,
  });

  static PgsPcs parse(ByteData data, int pts) {
    // offset 0: width (2)
    // offset 2: height (2)
    // offset 4: frame_rate (1)
    // offset 5: composition_number (2)
    // offset 7: state (1)
    // offset 8: palette_update_flag (1)
    // offset 9: palette_id (1)
    // offset 10: number_of_composition_objects (1)
    
    final width = data.getUint16(0);
    final height = data.getUint16(2);
    final frameRate = data.getUint8(4);
    final compositionNumber = data.getUint16(5);
    final stateRaw = data.getUint8(7);
    final state = CompositionState.values.firstWhere((e) => e.index == (stateRaw >> 6), orElse: () => CompositionState.normal);
    final paletteId = data.getUint8(9);
    
    final count = data.getUint8(10);
    final objects = <PgsCompositionObject>[];
    
    int offset = 11;
    for (int i = 0; i < count; i++) {
      if (offset + 8 > data.lengthInBytes) break;
      final objId = data.getUint16(offset);
      final winId = data.getUint8(offset + 2);
      final cropped = data.getUint8(offset + 3) == 0x40;
      final x = data.getUint16(offset + 4);
      final y = data.getUint16(offset + 6);
      
      // We ignore crop details for simplicity
      int len = 8;
      if (cropped) {
        len += 8; // Crop info
      }
      
      objects.add(PgsCompositionObject(objectId: objId, windowId: winId, x: x, y: y));
      offset += len;
    }

    return PgsPcs(
      pts: pts,
      width: width,
      height: height,
      frameRate: frameRate,
      compositionNumber: compositionNumber,
      state: state,
      paletteId: paletteId,
      objects: objects,
    );
  }
}

enum CompositionState {
  normal, // 0x00
  acquisitionPoint, // 0x40
  epochStart, // 0x80
}

class PgsCompositionObject {
  final int objectId;
  final int windowId;
  final int x;
  final int y;
  
  PgsCompositionObject({required this.objectId, required this.windowId, required this.x, required this.y});
}

class PgsPds {
  final int id;
  final int version;
  final Map<int, int> palette; // Index -> ARGB

  PgsPds({required this.id, required this.version, required this.palette});

  static PgsPds parse(ByteData data) {
    final id = data.getUint8(0);
    final version = data.getUint8(1);
    final palette = <int, int>{};
    
    int offset = 2;
    while (offset + 5 <= data.lengthInBytes) {
      final index = data.getUint8(offset);
      final y = data.getUint8(offset + 1);
      final cr = data.getUint8(offset + 2);
      final cb = data.getUint8(offset + 3);
      final a = data.getUint8(offset + 4);
      
      // Convert YCrCbA to ARGB
      // Y: 16-235, Cb/Cr: 16-240.
      // Standard HDTV (BT.709) or SDTV (BT.601)? PGS is typically HD (BT.709).
      // But standard formulas work reasonably well.
      
      final yValue = y.toDouble();
      final cbValue = cb.toDouble();
      final crValue = cr.toDouble();
      
      final r = (yValue + 1.402 * (crValue - 128)).clamp(0, 255).toInt();
      final g = (yValue - 0.344136 * (cbValue - 128) - 0.714136 * (crValue - 128)).clamp(0, 255).toInt();
      final b = (yValue + 1.772 * (cbValue - 128)).clamp(0, 255).toInt();
      
      // Alpha in PGS is 0=Transparent, 255=Opaque.
      // Store as Int32 ARGB
      palette[index] = (a << 24) | (r << 16) | (g << 8) | b;
      
      offset += 5;
    }
    
    return PgsPds(id: id, version: version, palette: palette);
  }
}

class PgsOds {
  final int id;
  final int version;
  final int width;
  final int height;
  final Uint8List rleData;

  PgsOds({
    required this.id,
    required this.version,
    required this.width,
    required this.height,
    required this.rleData,
  });

  static PgsOds parse(ByteData data) {
    final id = data.getUint16(0);
    final version = data.getUint8(2);
    // sequence_flag = data.getUint8(3);
    // 0x80 = First, 0x40 = Last.
    // data_length (3 bytes) -> 4,5,6
    
    // We assume the object data is contiguous in one segment for simplicity 
    // (though large objects can be split).
    // If we support split, we need to accumulate.
    // For this implementation, we take what we have.
    
    final width = data.getUint16(7);
    final height = data.getUint16(9);
    
    final rleData = data.buffer.asUint8List(data.offsetInBytes + 11, data.lengthInBytes - 11);
    
    return PgsOds(
      id: id,
      version: version,
      width: width,
      height: height,
      rleData: rleData,
    );
  }
}
