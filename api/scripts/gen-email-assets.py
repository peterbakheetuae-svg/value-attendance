#!/usr/bin/env python3
"""Rebuilds src/lib/email-assets.ts from assets/email/* (run from api/)."""
import base64
parts = ["// GENERATED from api/assets/email/* (VALUNIVO email images, embedded so the serverless bundle carries them).",
         "// Regenerate with: python3 scripts/gen-email-assets.py — do not edit by hand.", ""]
for name, file, ctype in [('ICON', 'icon.png', 'image/png'), ('WORDMARK', 'wordmark.png', 'image/png'), ('HEADER_BG', 'header-bg.jpg', 'image/jpeg')]:
    b = base64.b64encode(open('assets/email/' + file, 'rb').read()).decode()
    parts.append(f"export const {name} = {{ filename: '{file}', contentType: '{ctype}', base64: '{b}' }};")
open('src/lib/email-assets.ts', 'w').write('\n'.join(parts) + '\n')
