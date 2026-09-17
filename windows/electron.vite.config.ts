import { defineConfig } from 'electron-vite'
import { resolve } from 'node:path'

export default defineConfig({
  main: {
    build: {
      outDir: 'out/main'
    }
  },
  preload: {
    build: {
      outDir: 'out/preload',
      rollupOptions: {
        input: {
          index: resolve(import.meta.dirname, 'src/preload/index.ts')
        }
      }
    }
  },
  renderer: {
    build: {
      outDir: 'out/renderer',
      rollupOptions: {
        input: {
          index: resolve(import.meta.dirname, 'src/renderer/index.html'),
          mirror: resolve(import.meta.dirname, 'src/renderer/mirror.html')
        }
      }
    }
  }
})
