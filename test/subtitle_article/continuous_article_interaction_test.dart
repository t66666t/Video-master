import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_engine.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_model.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';

void main() {
  testWidgets('hit testing maps each same-line sentence to its own index', (
    tester,
  ) async {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: const <String>['one', 'two', 'three'],
    );
    const style = TextStyle(fontSize: 16, height: 1.6);
    const key = ArticleLayoutKey(
      documentGeneration: 1,
      width: 400,
      style: style,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    final layout = const ArticleLayoutEngine().layout(
      document: document,
      key: key,
    );
    final active = ValueNotifier<List<int>>(<int>[]);
    int? tappedIndex;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 120,
          child: ContinuousArticleView(
            document: document,
            layout: layout,
            style: style,
            highlightStyle: style.copyWith(color: Colors.blueAccent),
            activeIndices: active,
            itemScrollController: ItemScrollController(),
            itemPositionsListener: ItemPositionsListener.create(),
            onSubtitleTap: (index) => tappedIndex = index,
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
    await tester.pump();

    final lineFinder = find.byKey(const ValueKey('subtitle-continuous-line-0'));
    final lineText = tester.widget<Text>(
      find.byKey(const ValueKey('subtitle-continuous-line-text-0')),
    );
    expect(lineText.overflow, TextOverflow.visible);

    final painter = TextPainter(
      text: TextSpan(text: document.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 400);
    final second = document.sentenceForDisplayIndex(1)!;
    final secondBox = painter
        .getBoxesForSelection(
          TextSelection(baseOffset: second.start, extentOffset: second.end),
        )
        .single
        .toRect();
    await tester.tapAt(tester.getTopLeft(lineFinder) + secondBox.center);
    await tester.pump();
    expect(tappedIndex, 1);

    tappedIndex = null;
    final separatorX = painter
        .getOffsetForCaret(TextPosition(offset: second.start - 1), Rect.zero)
        .dx;
    await tester.tapAt(
      tester.getTopLeft(lineFinder) + Offset(separatorX, secondBox.center.dy),
    );
    await tester.pump();
    expect(tappedIndex, isNull);

    painter.dispose();
    active.dispose();
  });
}
