import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shikiin/widgets/app_icon_button.dart';

void main() {
  testWidgets('tap fires onPressed and shows default icon', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppIconButton(
        id: AppIconId.playPause, size: 40, iconSize: 24, color: Colors.white,
        onPressed: () => tapped = true,
      )),
    ));
    expect(find.byIcon(defaultIconData(AppIconId.playPause)), findsOneWidget);
    await tester.tap(find.byType(AppIconButton));
    expect(tapped, true);
  });

  testWidgets('playing 态用 pause 图标（同一按钮换图标）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppIconButton(
        id: AppIconId.pause, size: 40, iconSize: 24, color: Colors.white, onPressed: () {},
      )),
    ));
    expect(find.byIcon(defaultIconData(AppIconId.pause)), findsOneWidget);
    expect(find.byIcon(defaultIconData(AppIconId.playPause)), findsNothing);
  });
}
