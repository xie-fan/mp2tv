import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import type { Mp2tvApi } from '../shared/api'

const INVOKE = [
  'app:getState',
  'qr:refresh',
  'device:unpair',
  'device:rename',
  'settings:set',
  'logs:export',
  'mirror:ready',
  'session:stop',
  'session:command',
  'window:toggleFullscreen',
  'window:windowed',
  'window:setPin',
  'window:closeMirror'
]
const ON = ['paired', 'devices', 'qr', 'session:start', 'session:reconnecting', 'session:resume', 'media', 'window:state']

const api: Mp2tvApi = {
  invoke: (channel: string, ...args: unknown[]): Promise<unknown> => {
    if (!INVOKE.includes(channel)) return Promise.reject(new Error(`bad channel ${channel}`))
    return ipcRenderer.invoke(channel, ...args)
  },
  on: (channel: string, cb: (...args: unknown[]) => void): (() => void) => {
    if (!ON.includes(channel)) throw new Error(`bad channel ${channel}`)
    const l = (_e: IpcRendererEvent, ...args: unknown[]) => cb(...args)
    ipcRenderer.on(channel, l)
    return () => ipcRenderer.removeListener(channel, l)
  }
}

contextBridge.exposeInMainWorld('mp2tv', api)
