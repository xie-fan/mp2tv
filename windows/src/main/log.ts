import fs from 'node:fs'
import path from 'node:path'

let logFile: string | null = null

export function initLog(dir: string): string {
  fs.mkdirSync(dir, { recursive: true })
  logFile = path.join(dir, 'mp2tv.log')
  return logFile
}

export function getLogFile(): string | null {
  return logFile
}

export function log(...args: unknown[]): void {
  const line = `[${new Date().toISOString()}] ${args.map((a) => (a instanceof Error ? a.stack ?? a.message : typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`
  process.stdout.write(line)
  if (logFile) {
    try {
      fs.appendFileSync(logFile, line)
    } catch {
      /* ignore */
    }
  }
}
