#!/usr/bin/env bash
# Prints the raw Ed25519 public key (base64) of a release key PEM — what the Windows app is compiled with
# (--dart-define=UPDATE_PUBLIC_KEY=...). The public half is not a secret.
set -euo pipefail
openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | base64 -w0
