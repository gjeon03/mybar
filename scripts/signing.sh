# Sourced by build-app.sh and package.sh. Picks the code-signing identity:
# MYBAR_SIGN_IDENTITY, else a "Developer ID Application" certificate in the
# keychain, else ad hoc ("-"). Ad-hoc signatures change with every build, so
# macOS forgets granted permissions after each update; a certificate keeps them.
default_identity="-"
developer_id="$(security find-identity -v -p codesigning 2>/dev/null |
  sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
if [ -n "$developer_id" ]; then
  default_identity="$developer_id"
fi
identity="${MYBAR_SIGN_IDENTITY:-$default_identity}"

# Signs the bundle or disk image at $1 with $identity; a real certificate gets
# a secure timestamp, which notarization requires.
sign() {
  if [ "$identity" = "-" ]; then
    codesign --force --options runtime --sign - "$1"
  else
    codesign --force --options runtime --timestamp --sign "$identity" "$1"
  fi
}
