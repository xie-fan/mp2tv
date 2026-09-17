export interface Mp2tvApi {
  invoke: (channel: string, ...args: unknown[]) => Promise<unknown>
  on: (channel: string, cb: (...args: unknown[]) => void) => () => void
}
