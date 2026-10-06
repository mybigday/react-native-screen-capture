const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const ts = require('typescript')
const code = ts.transpileModule(fs.readFileSync('src/index.ts', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS },
}).outputText
const results = []
function load() {
  const counts = { start: 0, stop: 0, capture: 0 }
  let appState
  const handlers = new Set()
  const native = {
    startScreenshotDetection: async () => { counts.start++ },
    stopScreenshotDetection: async () => { counts.stop++ },
    capture: async (options) => { counts.capture++; return options },
    getPermissionStatus: async () => 'granted',
    releaseCapture: async (uri) => uri,
  }
  const module = { exports: {} }
  vm.runInNewContext(code, {
    module, exports: module.exports,
    require: (name) => {
      if (name === './NativeScreenCapture') return { default: native }
      assert.equal(name, 'react-native')
      return {
        Platform: { OS: 'android' }, NativeModules: { ScreenCapture: native },
        AppState: { addEventListener: (_, handler) => { appState = handler } },
        NativeEventEmitter: class {
          addListener(_, handler) { handlers.add(handler); return { remove() { handlers.delete(handler) } } }
        },
      }
    },
  })
  return { api: module.exports, native, counts, foreground: () => appState('active'),
    emit: (event) => handlers.forEach(handler => handler(event)) }
}
const flush = () => new Promise(resolve => setImmediate(resolve))
async function test(name, body) { await body(); results.push({ name, passed: true }) }
async function main() {
  await test('two subscribers start once; double remove does not stop the other', async () => {
    const x = load(); let events = 0
    const a = x.api.addScreenshotListener(() => events++)
    const b = x.api.addScreenshotListener(() => events++)
    await flush(); assert.equal(x.counts.start, 1)
    a.remove(); a.remove(); await flush(); assert.equal(x.counts.stop, 0)
    x.emit({}); assert.equal(events, 1)
    b.remove(); await flush(); assert.equal(x.counts.stop, 1)
  })
  await test('failed start retries with another subscriber and on foreground', async () => {
    const x = load(); let fail = true
    x.native.startScreenshotDetection = async () => { x.counts.start++; if (fail) throw Error('injected') }
    const a = x.api.addScreenshotListener(() => {})
    await flush(); assert.equal(x.counts.start, 1)
    const b = x.api.addScreenshotListener(() => {})
    await flush(); assert.equal(x.counts.start, 2)
    fail = false; x.foreground(); await flush(); assert.equal(x.counts.start, 3)
    a.remove(); b.remove(); await flush(); assert.equal(x.counts.stop, 1)
  })
  await test('remove/readd during pending start preserves one running detector', async () => {
    const x = load(); let complete
    x.native.startScreenshotDetection = () => { x.counts.start++; return new Promise(r => complete = r) }
    const a = x.api.addScreenshotListener(() => {}); await flush()
    a.remove(); const b = x.api.addScreenshotListener(() => {})
    complete(); await flush(); assert.equal(x.counts.start, 1); assert.equal(x.counts.stop, 0)
    b.remove(); await flush(); assert.equal(x.counts.stop, 1)
  })
  await test('remove during pending start eventually stops detection', async () => {
    const x = load(); let complete
    x.native.startScreenshotDetection = () => { x.counts.start++; return new Promise(r => complete = r) }
    const a = x.api.addScreenshotListener(() => {}); await flush(); a.remove()
    complete(); await flush(); assert.equal(x.counts.stop, 1)
  })
  await test('invalid scale rejects before native capture; unknown probe flag survives', async () => {
    const x = load()
    for (const scale of [NaN, Infinity, -1, 0]) await assert.rejects(x.api.capture({ scale }))
    assert.equal(x.counts.capture, 0)
    const options = await x.api.capture({ mode: 'view', scale: 0.4, probeBranch: 'candidate' })
    assert.equal(options.probeBranch, 'candidate'); assert.equal(options.scale, 0.4)
    assert.equal(await x.api.releaseCapture('file:///owned.png'), 'file:///owned.png')
  })
  console.log(JSON.stringify(results, null, 2))
}
main().catch(error => { console.error(error); process.exitCode = 1 })
