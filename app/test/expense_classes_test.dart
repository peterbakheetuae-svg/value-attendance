import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/jph/pages/cash/expense_classes.dart';

/// مجموعات وتصنيفات المصروفات: the form's two optional pickers and the card's chip (no network here).
void main() {
  const classes = ExpenseClasses(installed: true, canManage: true, groups: [
    {'id': 'g1', 'name': 'تشغيل المكتب', 'categoryIds': ['c1', 'c3']},
    {'id': 'g2', 'name': 'صيانة المقر', 'categoryIds': ['c2', 'c3']},
  ], categories: [
    {'id': 'c1', 'name': 'قهوة ومشروبات'},
    {'id': 'c2', 'name': 'دهانات'},
    {'id': 'c3', 'name': 'صيانة'},
  ]);

  test('a category reused by two groups; a group offers only its own categories', () {
    expect(classes.categoriesOf('g1').map((c) => c['id']), ['c1', 'c3']);
    expect(classes.categoriesOf('g2').map((c) => c['id']), ['c2', 'c3']);
    expect(classes.categoriesOf(null).length, 3, reason: 'no group → every category');
    expect(classes.groupName('g2'), 'صيانة المقر');
    expect(classes.categoryName(null), isNull);
  });

  testWidgets('the form shows nothing before 086, the two optional pickers after it', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ExpenseClassFields(isDark: false, classes: const ExpenseClasses(),
        groupId: null, categoryId: null, onChanged: (_, __) {}))));
    expect(find.text('المجموعة (اختياري)'), findsNothing);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Directionality(textDirection: TextDirection.rtl,
        child: ExpenseClassFields(isDark: false, classes: classes, groupId: 'g1', categoryId: 'c3', onChanged: (_, __) {})))));
    expect(find.text('المجموعة (اختياري)'), findsOneWidget);
    expect(find.text('تشغيل المكتب'), findsOneWidget);
    expect(find.text('صيانة'), findsOneWidget);
  });

  testWidgets('an expense card says «غير مصنف» or «المجموعة • التصنيف»', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      expenseClassChip(const {'expenseGroupName': null, 'expenseCategoryName': null}),
      expenseClassChip(const {'expenseGroupName': 'تشغيل المكتب', 'expenseCategoryName': 'قهوة ومشروبات'}),
    ]))));
    expect(find.text('غير مصنف'), findsOneWidget);
    expect(find.text('تشغيل المكتب • قهوة ومشروبات'), findsOneWidget);
  });
}
