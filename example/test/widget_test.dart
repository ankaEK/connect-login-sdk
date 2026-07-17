import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:login_with_connect_example/main.dart';

void main() {
  testWidgets('SignInDemo shows sign-in button', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SignInDemo()),
    );

    expect(find.text('SIGN IN'), findsOneWidget);
    expect(find.text('Not signed in.'), findsOneWidget);
  });
}
