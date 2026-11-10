import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/jph_form_ui.dart';

/// HR / المدير / the owner: delete an earlier form (asks first). Returns true when it was deleted.
Future<bool> deleteFormRecord(BuildContext context, String id, String label) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => GlassAlertDialog(
      icon: const Icon(Icons.delete_forever_rounded, color: Colors.red, size: 40),
      title: const Text('حذف الاستمارة'),
      content: Text('هتتحذف «$label» نهائيًا من الاستمارات السابقة. متأكد؟', textAlign: TextAlign.center),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('احذف'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  final r = await ApiService.post({'action': 'cash_post', 'method': 'delete', 'path': '/forms/$id', 'ok': 'اتحذفت الاستمارة ✅'});
  if (!context.mounted) return r['success'] == true;
  JphUi.toast(context, r);
  return r['success'] == true;
}

/// The small red delete button shown on an earlier form for those allowed.
Widget formDeleteButton(VoidCallback onTap) => IconButton(
      tooltip: 'حذف',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.delete_outline_rounded, color: Colors.red),
      onPressed: onTap,
    );
