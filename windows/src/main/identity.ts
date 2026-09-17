import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { safeStorage } from 'electron'
import {
  X509CertificateGenerator,
  BasicConstraintsExtension,
  KeyUsagesExtension,
  ExtendedKeyUsageExtension,
  KeyUsageFlags,
  ExtendedKeyUsage
} from '@peculiar/x509'

export interface Identity {
  certDer: Buffer
  certPem: string
  keyPem: string
  fingerprint: string
  receiverId: string
}

function toPem(der: Buffer, label: string): string {
  const b64 = der.toString('base64').replace(/(.{64})/g, '$1\n')
  return `-----BEGIN ${label}-----\n${b64}\n-----END ${label}-----\n`
}

function build(certDer: Buffer, keyDer: Buffer): Identity {
  const fingerprint = crypto.createHash('sha256').update(certDer).digest('hex')
  return {
    certDer,
    certPem: toPem(certDer, 'CERTIFICATE'),
    keyPem: toPem(keyDer, 'PRIVATE KEY'),
    fingerprint,
    receiverId: fingerprint.slice(0, 16)
  }
}

export async function loadOrCreateIdentity(userDataDir: string): Promise<Identity> {
  const file = path.join(userDataDir, 'identity.json')
  if (fs.existsSync(file)) {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'))
    const enc: Buffer =
      typeof j.keyEnc === 'string' ? Buffer.from(j.keyEnc, 'base64') : Buffer.from(j.keyEnc.data)
    const keyDer = Buffer.from(safeStorage.decryptString(enc), 'base64')
    return build(Buffer.from(j.certDer, 'base64'), keyDer)
  }

  const wc = crypto.webcrypto
  const keys = await wc.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const alg = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' }
  const cert = await X509CertificateGenerator.createSelfSigned(
    {
      serialNumber: '01',
      name: 'CN=mp2tv',
      notBefore: new Date(),
      notAfter: new Date(Date.now() + 20 * 365 * 86400e3),
      signingAlgorithm: alg,
      keys,
      extensions: [
        new BasicConstraintsExtension(false, undefined, true),
        new KeyUsagesExtension(KeyUsageFlags.digitalSignature, true),
        new ExtendedKeyUsageExtension([ExtendedKeyUsage.serverAuth], false)
      ]
    },
    wc
  )
  const certDer = Buffer.from(cert.rawData)
  const keyDer = Buffer.from(await wc.subtle.exportKey('pkcs8', keys.privateKey))
  fs.writeFileSync(
    file,
    JSON.stringify({
      certDer: certDer.toString('base64'),
      keyEnc: safeStorage.encryptString(keyDer.toString('base64')).toString('base64')
    })
  )
  return build(certDer, keyDer)
}
