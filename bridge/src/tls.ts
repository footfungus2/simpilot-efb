import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createSecureContext } from 'node:tls';

export type BridgeTls = { pfx: Buffer; passphrase: string; fingerprint: string };

function run(file: string, args: string[], env: NodeJS.ProcessEnv): Promise<string> {
  return new Promise((resolve, reject) => execFile(file, args, { env, windowsHide: true, timeout: 120_000 }, (error, stdout, stderr) => {
    if (error) reject(new Error(`${file} failed: ${String(stderr || error.message).trim()}`));
    else resolve(String(stdout));
  }));
}

async function readTls(dir: string, passphrase: string): Promise<BridgeTls> {
  const [pfx, fingerprint] = await Promise.all([
    fs.readFile(path.join(dir, 'bridge.pfx')),
    fs.readFile(path.join(dir, 'fingerprint.sha256'), 'utf8'),
  ]);
  const hash = fingerprint.trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(hash)) throw new Error('invalid bridge certificate fingerprint');
  createSecureContext({ pfx, passphrase });
  return { pfx, passphrase, fingerprint: hash };
}

async function generateTls(dir: string, passphrase: string): Promise<void> {
  const pfx = path.join(dir, 'bridge.pfx');
  const fingerprint = path.join(dir, 'fingerprint.sha256');
  const env = { ...process.env, SIMPILOT_PAIRING_KEY: passphrase, SIMPILOT_TLS_PFX: pfx, SIMPILOT_TLS_FINGERPRINT: fingerprint };
  if (process.platform === 'win32') {
    const script = String.raw`$ErrorActionPreference = 'Stop'
$cert = New-SelfSignedCertificate -DnsName 'simpilot.local' -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(10)
try {
  $password = ConvertTo-SecureString $env:SIMPILOT_PAIRING_KEY -AsPlainText -Force
  Export-PfxCertificate -Cert $cert -FilePath $env:SIMPILOT_TLS_PFX -Password $password -ChainOption EndEntityCertOnly | Out-Null
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $hash = [BitConverter]::ToString($sha.ComputeHash($cert.RawData)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
  [System.IO.File]::WriteAllText($env:SIMPILOT_TLS_FINGERPRINT, $hash)
} finally { Remove-Item (Join-Path 'Cert:\CurrentUser\My' $cert.Thumbprint) -DeleteKey -Force }`;
    await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], env);
    return;
  }

  const key = path.join(dir, 'bridge.key');
  const cert = path.join(dir, 'bridge.crt');
  // shortcut: the unencrypted PEM is confined to a user-only temporary directory; encrypt it if dev servers become multi-user.
  await run('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-sha256', '-nodes', '-keyout', key, '-out', cert, '-days', '3650', '-subj', '/CN=simpilot.local'], env);
  await run('openssl', ['pkcs12', '-export', '-out', pfx, '-inkey', key, '-in', cert, '-passout', 'env:SIMPILOT_PAIRING_KEY'], env);
  const output = await run('openssl', ['x509', '-in', cert, '-noout', '-fingerprint', '-sha256'], env);
  const match = /Fingerprint=([a-f0-9:]+)/i.exec(output);
  const hash = match?.[1]?.replaceAll(':', '').toLowerCase();
  if (!hash || !/^[a-f0-9]{64}$/.test(hash)) throw new Error('OpenSSL returned an invalid bridge certificate fingerprint');
  await fs.writeFile(fingerprint, hash, { mode: 0o600 });
  await Promise.all([fs.rm(key, { force: true }), fs.rm(cert, { force: true })]);
}

export async function loadOrCreateTls(dir: string, pairingKey: string): Promise<BridgeTls> {
  await fs.mkdir(path.dirname(dir), { recursive: true, mode: 0o700 });
  try { return await readTls(dir, pairingKey); } catch { await fs.rm(dir, { recursive: true, force: true }); }

  const temporary = await fs.mkdtemp(path.join(path.dirname(dir), '.simpilot-tls-'));
  try {
    await generateTls(temporary, pairingKey);
    try { await fs.rename(temporary, dir); }
    catch (error) {
      if (!['EEXIST', 'ENOTEMPTY'].includes((error as NodeJS.ErrnoException).code ?? '')) throw error;
    }
    return await readTls(dir, pairingKey);
  } finally {
    await fs.rm(temporary, { recursive: true, force: true });
  }
}
