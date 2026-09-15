#!/usr/bin/env python3
"""Create one user-local code-signing identity for repeated development builds."""
from pathlib import Path
import os
import re
import secrets
import shutil
import subprocess
import tempfile

NAME = "MacBook Duo Local Development"
DIRECTORY = Path.home() / "Library/Application Support/MacBook Duo/Signing"
KEYCHAIN = Path.home() / "Library/Keychains/login.keychain-db"
CERTIFICATE = DIRECTORY / "certificate.pem"


def run(arguments, **options):
    result = subprocess.run(arguments, **options)
    if result.returncode:
        raise SystemExit(f"{Path(arguments[0]).name} failed (exit {result.returncode}); no credential values are logged.")
    return result


def fingerprint():
    result = subprocess.check_output([
        "/usr/bin/openssl", "x509", "-in", str(CERTIFICATE),
        "-noout", "-fingerprint", "-sha1"
    ], text=True)
    return result.split("=", 1)[1].strip().replace(":", "")


DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(DIRECTORY, 0o700)
if not CERTIFICATE.exists():
    with tempfile.TemporaryDirectory(prefix="duo-signing-") as temporary:
        folder = Path(temporary)
        config = folder / "certificate.cnf"
        config.write_text("""[req]
prompt = no
distinguished_name = name
x509_extensions = signing
[name]
CN = MacBook Duo Local Development
[signing]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
""")
        key = folder / "key.pem"
        certificate = folder / "certificate.pem"
        package = folder / "identity.p12"
        password = secrets.token_hex(32)
        password_file = folder / "archive-password"
        password_file.write_text(password)
        os.chmod(password_file, 0o600)
        run(["/usr/bin/openssl", "req", "-new", "-newkey", "rsa:3072", "-x509",
             "-nodes", "-days", "3650", "-config", str(config),
             "-keyout", str(key), "-out", str(certificate)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key),
             "-in", str(certificate), "-name", NAME, "-out", str(package),
             "-descert", "-passout", "file:" + str(password_file)], stdout=subprocess.DEVNULL)
        os.chmod(package, 0o600)
        # The temporary directory is private. The imported private key becomes
        # non-extractable and grants access only to the system codesign tool.
        run(["/usr/bin/security", "import", str(package), "-k", str(KEYCHAIN),
             "-P", password, "-x", "-T", "/usr/bin/codesign"])
        shutil.copy2(certificate, CERTIFICATE)

identity = fingerprint()
assert re.fullmatch(r"[0-9A-F]{40}", identity)
identities = subprocess.check_output([
    "/usr/bin/security", "find-identity", "-p", "codesigning", str(KEYCHAIN)
], text=True)
if identity not in identities:
    raise SystemExit("The saved certificate has no matching keychain identity; no replacement key was created.")

valid = subprocess.check_output([
    "/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(KEYCHAIN)
], text=True)
if identity not in valid:
    # Trust is restricted to code signing in the current user's keychain.
    # This certificate has no TLS or certificate-authority usage.
    run(["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
         "-k", str(KEYCHAIN), str(CERTIFICATE)])
    valid = subprocess.check_output([
        "/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(KEYCHAIN)
    ], text=True)
if identity not in valid:
    raise SystemExit("Code-signing trust is not ready; the build configuration was not changed.")
configuration = DIRECTORY / "identity"
temporary_config = DIRECTORY / ".identity.new"
temporary_config.write_text(identity + "\n")
os.chmod(temporary_config, 0o600)
temporary_config.replace(configuration)
print(f"Ready: {NAME}")
print(f"Build configuration: {configuration}")
print("The private key remains in the login keychain; no key material is stored in the repository.")
