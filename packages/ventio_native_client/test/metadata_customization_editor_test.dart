import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ventio_core/ventio_core.dart';
import 'package:ventio_native_client/src/workspace_page.dart';

import '../../ventio_core/test/support/wave2_fixtures.dart';

void main() {
  for (final partial in [false, true]) {
    testWidgets(
      'Valid ${partial ? 'partial' : 'empty'} Host layout opens, edits and preserves package and field authority',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final base = ExtensionBundle.fromJson(w2BundleJson());
        final original = canonicalJson(base.toJson());
        final digest = sha256.convert(utf8.encode(original)).toString();
        final body = w2Overlay(hash: digest);
        if (partial) {
          body['ui'] = {
            'formFields': ['secret', 'name', 'custom_note'],
          };
        }
        // This valid Host contract is the shape that crashed the installed UI.
        MetadataCustomization.fromJson(body).merge(base);
        Map<String, dynamic>? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    saved = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => MetadataCustomizationEditor(
                        body: body,
                        base: base,
                        definition: base.docTypes.single,
                        namespace: 'extension.com_example_wave2',
                      ),
                    );
                  },
                  child: const Text('Open customization'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open customization'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsOneWidget);
        final customChips = find.widgetWithText(FilterChip, 'Custom note');
        expect(customChips, findsNWidgets(3));
        expect(tester.widget<FilterChip>(customChips.at(0)).selected, isFalse);
        expect(tester.widget<FilterChip>(customChips.at(1)).selected, partial);
        if (!partial) {
          await tester.ensureVisible(customChips.at(1));
          await tester.tap(customChips.at(1));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('Save local draft'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(saved, isNotNull);
        final ui = saved!['ui'] as Map;
        expect(ui['listColumns'], ['name']);
        expect(ui['detailFields'], ['name', 'secret']);
        expect(
          ui['formFields'],
          partial
              ? ['secret', 'name', 'custom_note']
              : ['name', 'secret', 'custom_note'],
        );
        expect(saved!['baseSha256'], digest);
        expect(saved!['fields'], body['fields']);
        MetadataCustomization.fromJson(
          saved!,
        ).merge(base, previous: MetadataCustomization.fromJson(body));
        expect(canonicalJson(base.toJson()), original);
      },
    );
  }
}
