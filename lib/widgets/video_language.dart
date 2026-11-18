import 'package:flutter/material.dart';
import '../services/app_settings.dart';

Future<String?> chooseVideoLanguage(BuildContext context, String current) =>
    showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Ngôn ngữ của video'),
        children: [
          for (final entry in kLanguages.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Row(
                children: [
                  Icon(
                    entry.key == current
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  const SizedBox(width: 12),
                  Text(entry.value),
                ],
              ),
            ),
        ],
      ),
    );
